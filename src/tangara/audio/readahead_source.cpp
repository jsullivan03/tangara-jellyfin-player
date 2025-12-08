/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "audio/readahead_source.hpp"
#include "audio/readahead_runner.hpp"

#include "esp_log.h"

namespace audio {

static constexpr char kTag[] = "readahead";

// This buffer is statically allocated in SPIRAM to ensure that allocation doesn't fail due
// to heap fragmentation. Its size is limited by peak heap usage during boot, which is
// largely determined by the font loading process.
static constexpr size_t kReadaheadStreamBufferSize = 1024 * 1024 + 1;
static EXT_RAM_BSS_ATTR uint8_t sReadaheadStreamBufferStorage[kReadaheadStreamBufferSize];

static constexpr size_t kFileReadBufferSize = 1024 * 32;
static EXT_RAM_BSS_ATTR std::array<std::byte, kFileReadBufferSize> sFileReadBuffer;

static_assert((kReadaheadStreamBufferSize - 1) % kFileReadBufferSize == 0,
              "kReadaheadStreamBufferSize must be an integer multiple of kFileReadBufferSize"
              " + 1 for an integer multiple of kFileReadBufferSize to fit in the streambuffer.");

ReadaheadSource::ReadaheadSource(std::unique_ptr<codecs::IStream> wrapped, ReadaheadRunner& runner)
    : IStream(wrapped->type()),
      wrapped_(std::move(wrapped)),
      tell_(wrapped_->CurrentPosition()),
      streambuffer_(nullptr),
      streambuffer_static_(),
      reading_file_(false),
      end_of_file_buffered_(false),
      shutting_down_(false),
      runner_(runner)
{}

ReadaheadSource::~ReadaheadSource() {
  // Tell the file reading task to stop.
  shutting_down_ = true;
  // If the file reading task is blocked on sending to the stream buffer,
  // unblock it by draining the buffer.
  // The size of this buffer is arbitrary.
  std::array<std::byte, 1024> drain;
  while (xStreamBufferSpacesAvailable(streambuffer_) < kFileReadBufferSize) {
    xStreamBufferReceive(streambuffer_, drain.data(), drain.size(), 0);
  }
  // Wait until the file reading task confirms it has stopped before
  // freeing memory it accesses.
  reading_file_.wait(true);

  vStreamBufferDelete(streambuffer_);
}

auto ReadaheadSource::Read(std::span<std::byte> dest) -> ssize_t {
  size_t bytes_written = 0;
  if (reading_file_ || end_of_file_buffered_) {
    while (!dest.empty()) {
      ESP_LOGV(kTag, "streambuffer has %u kb available to read", xStreamBufferBytesAvailable(streambuffer_) / 1024);
      // First try a nonblocking read
      size_t bytes_read = xStreamBufferReceive(streambuffer_, dest.data(), dest.size_bytes(), 0);
      if (bytes_read == 0) {
        // If the file reading task reached the end of the file,
        // avoid waiting; just return early.
        if (end_of_file_buffered_) {
          return 0;
        }
        ESP_LOGW(kTag, "cache miss; waiting for streambuffer to be filled");
        // There is no option here but to wait. This is working with encoded bytes
        // before they go to the decoder, not decoded PCM samples, so filling dest with 0s
        // would send invalid data to the decoder.
        bytes_read = xStreamBufferReceive(streambuffer_, dest.data(), dest.size_bytes(), portMAX_DELAY);
      }

      tell_ += bytes_read;
      bytes_written += bytes_read;
      dest = dest.subspan(bytes_read);
    }
  } else {
    // Codec is opening the stream and the background file reader task has not started yet,
    // so use the wrapped stream directly.
    while (!dest.empty()) {
      ESP_LOGV(kTag, "reading %u bytes from stream directly without streambuffer", dest.size_bytes());
      size_t bytes_read = wrapped_->Read(dest);
      tell_ += bytes_read;
      bytes_written += bytes_read;

      // Check for EOF in the wrapped stream.
      if (bytes_read < dest.size_bytes()) {
        break;
      } else {
        dest = dest.subspan(bytes_read);
      }
    }
  }

  return bytes_written;
}

auto ReadaheadSource::CanSeek() -> bool {
  return wrapped_->CanSeek();
}

auto ReadaheadSource::SeekTo(int64_t destination, SeekFrom from) -> void {
  // This function gets called by the codec before the file reading task starts.
  // Seeking from the UI creates a whole new ReadaheadSource and deletes the
  // old one, so there is no need to clear the buffers here.
  assert(!reading_file_);

  wrapped_->SeekTo(destination, from);
  tell_ = wrapped_->CurrentPosition();
}

auto ReadaheadSource::CurrentPosition() -> int64_t {
  return tell_;
}

auto ReadaheadSource::Size() -> std::optional<int64_t> {
  return wrapped_->Size();
}

auto ReadaheadSource::ReadFile() -> void {
  reading_file_ = true;
  while (!shutting_down_) {
    ssize_t read = wrapped_->Read(sFileReadBuffer);
    if (read > 0) {
      // If the streambuffer is full, block until the reader clears enough space
      // to write again. Because the file read has already happened at this point,
      // refilling the streambuffer to its capacity is very fast.
      xStreamBufferSend(streambuffer_, sFileReadBuffer.data(), read, portMAX_DELAY);
      ESP_LOGV(kTag, "wrote %u kb to streambuffer", read / 1024);
    } else if (read == 0) {
      end_of_file_buffered_ = true;
      ESP_LOGV(kTag, "end of file buffered");
      break;
    } else if (read < 0) {
      ESP_LOGW(kTag, "error reading file");
    }
  }
  reading_file_ = false;
  reading_file_.notify_all();
}

auto ReadaheadSource::SetPreambleFinished() -> void {
  assert(!streambuffer_);
  streambuffer_ = xStreamBufferCreateStatic(kReadaheadStreamBufferSize, 1, sReadaheadStreamBufferStorage, &streambuffer_static_);

  // SD card reads can get very slow at the beginning of the file, so
  // block on partially filling the streambuffer to reduce cache misses when playback starts.
  // Don't completely fill it because that would frequently create a noticeable delay when loading tracks.
  // This partial filling sometimes results in a noticeable delay when loading tracks, however, that is better
  // than starting to play then hearing a few stutters at the beginning of the track before the cache fills up.
  // When the read speed is not super slow, this should not cause a noticeable delay.
  static constexpr size_t kPrefillSize = 1024 * 128;
  static_assert(kPrefillSize % kFileReadBufferSize == 0, "kPrefillSize must be an integer multiple of kFileReadBufferSize");
  for (int i = 0; i < kPrefillSize / kFileReadBufferSize; i++) {
    size_t read = wrapped_->Read(sFileReadBuffer);
    if (read > 0) {
      xStreamBufferSend(streambuffer_, sFileReadBuffer.data(), read, portMAX_DELAY);
    }
  }

  // ReadaheadRunner executes ReadaheadSource::ReadFile in another task
  runner_.RunInstance(this);
}

}  // namespace audio
