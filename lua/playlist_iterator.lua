local PlaylistIterator = {}

function PlaylistIterator:is_playlist(item)
  return item:filepath():match("%.playlist$")
      or item:filepath():match("%.m3u8?$")
end

function PlaylistIterator:create(fs_iterator)
  local iterator = fs_iterator:clone()
  local obj = {};

  local find_matching = function(iterate_fn)
    local next = iterate_fn(iterator);
    while next and (not PlaylistIterator:is_playlist(next) and not next:is_directory()) do
      next = iterate_fn();
    end
    return next;
  end

  function obj:clone()
    return PlaylistIterator:create(iterator)
  end

  function obj:next()
    return find_matching(iterator.next)
  end

  function obj:prev()
    return find_matching(iterator.prev)
  end

  return obj
end

return PlaylistIterator
