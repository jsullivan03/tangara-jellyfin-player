/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include <stdint.h>
#include <string>

#include "database/track.hpp"
#include "lru_cache.hpp"

namespace database {

class ITagParser {
 public:
  virtual ~ITagParser() {}
  virtual auto ReadAndParseTags(std::string_view path)
      -> std::shared_ptr<TrackTags> = 0;

  virtual auto ClearCaches() -> void {}
};

class TagParserImpl : public ITagParser {
 public:
  TagParserImpl();
  auto ReadAndParseTags(std::string_view path)
      -> std::shared_ptr<TrackTags> override;

  auto ClearCaches() -> void override;

 private:
  std::vector<std::unique_ptr<ITagParser>> parsers_;

  /*
   * Cache of tags that have already been extracted from files. Ideally this
   * cache should be slightly larger than any page sizes in the UI.
   */
  std::mutex cache_mutex_;
  util::LruCache<8, std::pmr::string, std::shared_ptr<TrackTags>> cache_;
};

class OggTagParser : public ITagParser {
 public:
  OggTagParser();
  auto ReadAndParseTags(std::string_view path)
      -> std::shared_ptr<TrackTags> override;

 private:
  auto parseComments(TrackTags&, std::span<unsigned char> data) -> void;
  auto parseLength(std::span<unsigned char> data) -> uint64_t;
};

class GenericTagParser : public ITagParser {
 public:
  auto ReadAndParseTags(std::string_view path)
      -> std::shared_ptr<TrackTags> override;

 private:
  // Supported file extensions for parsing tags, derived from the list of
  // supported audio formats here:
  // https://cooltech.zone/tangara/docs/music-library/
  static constexpr std::string supported_exts[] = {"flac", "mp3",  "ogg",
                                                   "ogx",  "opus", "wav"};
};

}  // namespace database
