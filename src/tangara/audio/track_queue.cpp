/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "audio/track_queue.hpp"
#include <stdint.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <variant>

#include "MillerShuffle.h"
#include "esp_random.h"

#include "audio/audio_events.hpp"
#include "audio/audio_fsm.hpp"
#include "cppbor.h"
#include "cppbor_parse.h"
#include "database/database.hpp"
#include "database/track.hpp"
#include "events/event_queue.hpp"
#include "memory_resource.hpp"
#include "random.hpp"
#include "tasks.hpp"
#include "track_queue.hpp"
#include "ui/ui_fsm.hpp"

namespace audio {

[[maybe_unused]] static constexpr char kTag[] = "tracks";

using Reason = QueueUpdate::Reason;

RandomIterator::RandomIterator() : seed_(0), pos_(0), size_(0) {}

RandomIterator::RandomIterator(size_t size) : seed_(), pos_(0), size_(size) {
  esp_fill_random(&seed_, sizeof(seed_));
}

auto RandomIterator::current() const -> size_t {
  if (size_ == 0) {
    return 0;
  }
  return MillerShuffle(pos_, seed_, size_);
}

auto RandomIterator::next(bool repeat) -> bool {
  // MillerShuffle behaves well with pos > size, returning different
  // permutations each 'cycle'. We therefore don't need to worry about wrapping
  // this value.
  if (pos_ < size_ - 1 || repeat) {
    pos_++;
    return true;
  }
  return false;
}

auto RandomIterator::prev() -> void {
  if (pos_ > 0) {
    pos_--;
  }
}

auto RandomIterator::resize(size_t s) -> void {
  size_ = s;
  // Changing size will yield a different current position anyway, so reset pos
  // to ensure we yield a full sweep of both new and old indexes.
  pos_ = 0;
}

auto notifyChanged(bool current_changed, Reason reason) -> void {
  QueueUpdate ev{
      .current_changed = current_changed,
      .reason = reason,
  };
  events::Ui().Dispatch(ev);
  events::Audio().Dispatch(ev);
}

auto notifyPlayFrom(uint32_t start_from_position) -> void {
  QueueUpdate ev{
      .current_changed = true,
      .reason = Reason::kExplicitUpdate,
      .seek_to_second = start_from_position,
  };
  events::Ui().Dispatch(ev);
  events::Audio().Dispatch(ev);
}

TrackQueue::TrackQueue(tasks::WorkerPool& bg_worker,
                       database::Handle db,
                       drivers::NvsStorage& nvs)
    : mutex_(),
      bg_worker_(bg_worker),
      db_(db),
      nvs_(nvs),
      playlist_(".queue.playlist"),
      position_(0),
      shuffle_(),
      repeatMode_(static_cast<RepeatMode>(nvs.QueueRepeatMode())),
      cancel_appending_async_(false),
      appending_async_(false),
      loading_(false),
      ready_(true) {}

auto TrackQueue::current() const -> TrackItem {
  const std::shared_lock<std::shared_mutex> lock(mutex_);
  if (!ready_) {
    return {};
  }
  std::string val;
  if (opened_playlist_ && position_ < opened_playlist_->size()) {
    val = opened_playlist_->value();
  } else {
    val = playlist_.value();
  }
  if (val.empty()) {
    return {};
  }
  return val;
}

auto TrackQueue::playFromPosition(const std::string& filepath,
                                  uint32_t position) -> void {
  clear();
  {
    const std::unique_lock<std::shared_mutex> lock(mutex_);
    playlist_.append(filepath);
    ready_ = true;
    updateShuffler(true);
  }
  notifyPlayFrom(position);
}

auto TrackQueue::currentPosition() const -> size_t {
  const std::shared_lock<std::shared_mutex> lock(mutex_);
  return position_;
}

auto TrackQueue::totalSize() const -> size_t {
  size_t sum = playlist_.size();
  if (opened_playlist_) {
    sum += opened_playlist_->size();
  }
  return sum;
}

auto TrackQueue::updateShuffler(bool andUpdatePosition) -> void {
  if (shuffle_) {
    shuffle_->resize(totalSize());
    if (andUpdatePosition) {
      goTo(shuffle_->current());
    }
  }
}

auto TrackQueue::open() -> bool {
  // FIX ME: If playlist opening fails, should probably fall back to a vector of
  // tracks or something so that we're not necessarily always needing mounted
  // storage
  return playlist_.open();
}

auto TrackQueue::close() -> void {
  playlist_.close();
  if (opened_playlist_) {
    opened_playlist_->close();
  }
}

auto TrackQueue::openPlaylist(const std::string& playlist_file, bool notify)
    -> bool {
  opened_playlist_.emplace(playlist_file);
  auto res = opened_playlist_->open();
  if (!res) {
    return false;
  }
  ready_ = true;
  updateShuffler(true);
  if (notify) {
    notifyChanged(true, Reason::kExplicitUpdate);
  }
  return true;
}

auto TrackQueue::getFilepath(database::TrackId id)
    -> std::optional<std::string> {
  auto db = db_.lock();
  if (!db) {
    return {};
  }
  return db->getTrackPath(id);
}

auto TrackQueue::append(Item i) -> void {
  bool was_queue_empty;
  bool current_changed;
  {
    const std::shared_lock<std::shared_mutex> lock(mutex_);
    was_queue_empty = currentPosition() >= totalSize();
    current_changed = was_queue_empty;  // Dont support inserts yet
  }

  if (std::holds_alternative<database::TrackId>(i)) {
    {
      const std::unique_lock<std::shared_mutex> lock(mutex_);
      auto filename = getFilepath(std::get<database::TrackId>(i)).value_or("");
      if (!filename.empty()) {
        playlist_.append(filename);
      }
      ready_ = true;
      updateShuffler(was_queue_empty);
    }
    notifyChanged(current_changed, Reason::kExplicitUpdate);
  } else if (std::holds_alternative<std::string>(i)) {
    auto& path = std::get<std::string>(i);
    if (!path.empty()) {
      {
        const std::unique_lock<std::shared_mutex> lock(mutex_);
        playlist_.append(std::get<std::string>(i));
        ready_ = true;
        updateShuffler(was_queue_empty);
      }
      notifyChanged(current_changed, Reason::kExplicitUpdate);
    }
  } else if (std::holds_alternative<database::TrackIterator>(i)) {
    // Iterators can be very large, and retrieving items from them often
    // requires disk i/o. Handle them asynchronously so that inserting them
    // doesn't block.
    appendAsync(std::get<database::TrackIterator>(i), was_queue_empty);
  }
}

auto TrackQueue::appendAsync(database::TrackIterator it, bool was_empty)
    -> void {
  // First, check whether or not an async append is already running. Grab the
  // mutex first to avoid races where we check appending_async_ between the bg
  // task looking at pending_async_iterators_ and resetting appending_async_.
  {
    const std::unique_lock<std::shared_mutex> lock(mutex_);
    if (appending_async_) {
      // We are already appending, so just add to the queue.
      pending_async_iterators_.push_back(it);
      return;
    } else {
      // We need to start a new task.
      appending_async_ = true;
      cancel_appending_async_ = false;
    }
  }

  bg_worker_.Dispatch<void>([=, this]() mutable {
    bool update_current = was_empty;
    if (update_current) {
      ready_ = false;
    }
    loading_ = true;
    size_t next_update_at = 10;

    while (!cancel_appending_async_) {
      auto next = *it;
      if (!next) {
        // The current iterator is out of tracks. Is there another iterator for
        // us to process?
        {
          const std::unique_lock<std::shared_mutex> lock(mutex_);
          if (!pending_async_iterators_.empty()) {
            // Yes. Grab it and continue.
            it = pending_async_iterators_.front();
            pending_async_iterators_.pop_front();
            continue;
          } else {
            // No, time to finish up.
            // First make sure the shuffler has the final count.
            updateShuffler(update_current);

            // Now reset all our state.
            loading_ = false;
            ready_ = true;
            appending_async_ = false;
            appending_async_.notify_all();
            notifyChanged(update_current, Reason::kExplicitUpdate);
            return;
          }
        }
      }

      // Keep this critical section small so that we're not blocking methods
      // like current().
      {
        const std::unique_lock<std::shared_mutex> lock(mutex_);
        auto filename = getFilepath(*next).value_or("");
        if (!filename.empty()) {
          playlist_.append(filename);
        }
      }
      it++;

      // Appending very large iterators can take a while. Send out periodic
      // queue updates during them so that the user has an idea what's going
      // on.
      if (!--next_update_at) {
        notifyChanged(false, Reason::kBulkLoadingUpdate);

        if (update_current) {
          if (shuffle_ && playlist_.size() >= 100) {
            // Special case for shuffling a large amount of tracks. Because
            // shuffling many tracks can be slow to wait for them all to load,
            // we wait for 100 or so to load, then start initially with a random
            // track from this first lot.
            updateShuffler(true);
            ready_ = true;
            notifyChanged(true, Reason::kExplicitUpdate);
            update_current = false;
          } else if (!shuffle_ && playlist_.size() > 0) {
            // If the queue was empty, then we want to start playing the first
            // track without waiting for the entire queue to finish loading
            ready_ = true;
            notifyChanged(true, Reason::kExplicitUpdate);
            update_current = false;
          }
        } else {
          // Make sure the shuffler gets updated periodically so that skipping
          // tracks whilst we're still loading gives us the whole queue to play
          // with.
          updateShuffler(false);
        }

        next_update_at = util::sRandom->RangeInclusive(10, 20);
      }
    }

    // If we're here, then the async append must have been cancelled. Bail out
    // immediately and rely on whatever cancelled us to reset our state. This
    // is a little messy, but we would have to gain a lock on mutex_ to reset
    // ourselves properly, and at the moment the only thing that can cancel us
    // is clear().
    appending_async_ = false;
    appending_async_.notify_all();
  });
}

auto TrackQueue::next() -> void {
  next(Reason::kExplicitUpdate);
}

auto TrackQueue::currentPosition(size_t position) -> bool {
  {
    const std::shared_lock<std::shared_mutex> lock(mutex_);
    if (position >= totalSize()) {
      return false;
    }
    goTo(position);
  }

  // If we're explicitly setting the position, we want to treat it as though
  // the current track has changed, even if the position was the same
  notifyChanged(true, Reason::kExplicitUpdate);
  return true;
}

auto TrackQueue::goTo(size_t position) -> void {
  position_ = position;
  if (opened_playlist_) {
    if (position_ < opened_playlist_->size()) {
      opened_playlist_->skipTo(position_);
    } else {
      playlist_.skipTo(position_ - opened_playlist_->size());
    }
  } else {
    playlist_.skipTo(position_);
  }
}

auto TrackQueue::next(Reason r) -> void {
  bool changed = false;

  {
    const std::unique_lock<std::shared_mutex> lock(mutex_);

    if (shuffle_) {
      changed = shuffle_->next(repeatMode_ == RepeatMode::REPEAT_QUEUE);
      position_ = shuffle_->current();
    } else {
      if (position_ + 1 < totalSize()) {
        position_++;  // Next track
        changed = true;
      } else if (repeatMode_ == RepeatMode::REPEAT_QUEUE) {
        position_ = 0;  // Go to beginning
        changed = true;
      }
    }

    goTo(position_);
  }

  notifyChanged(changed, r);
}

auto TrackQueue::previous() -> void {
  bool changed = true;

  {
    const std::unique_lock<std::shared_mutex> lock(mutex_);
    if (shuffle_) {
      shuffle_->prev();
      position_ = shuffle_->current();
    } else {
      if (position_ > 0) {
        position_--;
      } else if (repeatMode_ == RepeatMode::REPEAT_QUEUE) {
        position_ = totalSize() - 1;  // Go to the end of the queue
      }
    }
    goTo(position_);
  }

  notifyChanged(changed, Reason::kExplicitUpdate);
}

auto TrackQueue::finish() -> void {
  if (repeatMode_ == RepeatMode::REPEAT_TRACK) {
    notifyChanged(true, Reason::kRepeatingLastTrack);
  } else {
    next(Reason::kTrackFinished);
  }
}

auto TrackQueue::clear() -> void {
  if (appending_async_) {
    cancel_appending_async_ = true;
    appending_async_.wait(true);
  }

  {
    const std::unique_lock<std::shared_mutex> lock(mutex_);
    position_ = 0;
    ready_ = false;
    loading_ = false;
    pending_async_iterators_.clear();
    playlist_.clear();
    opened_playlist_.reset();
    if (shuffle_) {
      shuffle_->resize(0);
    }
    notifyChanged(false, Reason::kTrackFinished);
  }
}

auto TrackQueue::random(bool en) -> void {
  {
    const std::unique_lock<std::shared_mutex> lock(mutex_);
    if (en) {
      shuffle_.emplace(totalSize());
    } else {
      shuffle_.reset();
    }
  }

  // Current track doesn't get randomised until next().
  notifyChanged(false, Reason::kExplicitUpdate);
}

auto TrackQueue::random() const -> bool {
  const std::shared_lock<std::shared_mutex> lock(mutex_);
  return shuffle_.has_value();
}

auto TrackQueue::repeatMode(RepeatMode mode) -> void {
  repeatMode_ = mode;
  nvs_.QueueRepeatMode(repeatMode_);
  notifyChanged(false, Reason::kExplicitUpdate);
}

auto TrackQueue::repeatMode() const -> RepeatMode {
  return repeatMode_;
}

auto TrackQueue::isLoading() const -> bool {
  const std::unique_lock<std::shared_mutex> lock(mutex_);
  return loading_;
}

auto TrackQueue::isReady() const -> bool {
  const std::unique_lock<std::shared_mutex> lock(mutex_);
  return ready_;
}

auto TrackQueue::serialise() -> std::string {
  cppbor::Array tracks{};
  cppbor::Map encoded;

  cppbor::Array metadata{
      cppbor::Uint{position_},
      cppbor::Uint{repeatMode_},
  };

  if (opened_playlist_) {
    metadata.add(cppbor::Tstr{opened_playlist_->filepath()});
  }

  encoded.add(cppbor::Uint{0}, std::move(metadata));

  if (shuffle_) {
    encoded.add(cppbor::Uint{1}, cppbor::Array{
                                     cppbor::Uint{shuffle_->size()},
                                     cppbor::Uint{shuffle_->seed()},
                                     cppbor::Uint{shuffle_->pos()},
                                 });
  }

  playlist_.serialiseCache();

  return encoded.toString();
}

TrackQueue::QueueParseClient::QueueParseClient(TrackQueue& queue)
    : queue_(queue), state_(State::kInit), i_(0), position_to_set_(0) {}

cppbor::ParseClient* TrackQueue::QueueParseClient::item(
    std::unique_ptr<cppbor::Item>& item,
    const uint8_t* hdrBegin,
    const uint8_t* valueBegin,
    const uint8_t* end) {
  if (state_ == State::kInit) {
    if (item->type() == cppbor::MAP) {
      state_ = State::kRoot;
    }
  } else if (state_ == State::kRoot) {
    if (item->type() == cppbor::UINT) {
      switch (item->asUint()->unsignedValue()) {
        case 0:
          state_ = State::kMetadata;
          break;
        case 1:
          state_ = State::kShuffle;
          break;
        default:
          state_ = State::kFinished;
      }
    }
  } else if (state_ == State::kMetadata) {
    if (item->type() == cppbor::ARRAY) {
      i_ = 0;
    } else if (item->type() == cppbor::UINT) {
      auto val = item->asUint()->unsignedValue();
      if (i_ == 0) {
        // First value == position
        // Save the position so we can apply it later when we have finished
        // serialising
        position_to_set_ = val;
      } else if (i_ == 1) {
        // Second value == repeat mode
        queue_.repeatMode_ = static_cast<RepeatMode>(val);
      }
      i_++;
    } else if (item->type() == cppbor::TSTR) {
      auto val = item->asTstr();
      queue_.openPlaylist(val->value(), false);
    }
  } else if (state_ == State::kShuffle) {
    if (item->type() == cppbor::ARRAY) {
      i_ = 0;
      queue_.shuffle_.emplace();
    } else if (item->type() == cppbor::UINT) {
      auto val = item->asUint()->unsignedValue();
      switch (i_) {
        case 0:
          queue_.shuffle_->size() = val;
          break;
        case 1:
          queue_.shuffle_->seed() = val;
          break;
        case 2:
          queue_.shuffle_->pos() = val;
          break;
        default:
          break;
      }
      i_++;
    }
  } else if (state_ == State::kFinished) {
  }
  return this;
}

cppbor::ParseClient* TrackQueue::QueueParseClient::itemEnd(
    std::unique_ptr<cppbor::Item>& item,
    const uint8_t* hdrBegin,
    const uint8_t* valueBegin,
    const uint8_t* end) {
  if (state_ == State::kInit) {
    state_ = State::kFinished;
  } else if (state_ == State::kRoot) {
    queue_.goTo(position_to_set_);
    state_ = State::kFinished;
  } else if (state_ == State::kMetadata) {
    if (item->type() == cppbor::ARRAY) {
      state_ = State::kRoot;
    }
  } else if (state_ == State::kShuffle) {
    if (item->type() == cppbor::ARRAY) {
      state_ = State::kRoot;
    }
  } else if (state_ == State::kFinished) {
  }
  return this;
}

auto TrackQueue::deserialise(const std::string& s) -> void {
  if (s.empty()) {
    return;
  }
  QueueParseClient client{*this};
  const uint8_t* data = reinterpret_cast<const uint8_t*>(s.data());
  cppbor::parse(data, data + s.size(), &client);
  notifyChanged(true, Reason::kDeserialised);
}

}  // namespace audio
