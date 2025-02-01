
local TableIterator = {}

function TableIterator:create(table)
  local iterator = {};
  iterator.index = 0;
  iterator.table = table;

  function iterator:clone()
    return TableIterator:create(table)
  end
  
  function iterator:next()
    self.index = self.index + 1
    return self.table[self.index]
  end  
  
  function iterator:prev()
    self.index = self.index - 1
    return self.table[self.index]
  end

  return iterator
end


return TableIterator