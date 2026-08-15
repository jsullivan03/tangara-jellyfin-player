package.path = "desktop-sim/?.lua;lua/?.lua;" .. package.path
local lvgl = require("lvgl")
local backstack = require("firmware_backstack")
lvgl.ImgData = function(path) return path end
local encoder_mode = false
_G.tangara_sim_enable_encoder_handler = true
_G.tangara_sim_set_encoder_mode = function(enabled) encoder_mode = enabled == true end
require("mocks").install(lvgl)
package.loaded["backstack"] = backstack
package.preload["backstack"] = function() return backstack end
local screen = require("screen")
local list_ui = require("jellyfin_list_ui")
local virtual_list = require("jellyfin_virtual_list")
local items = {}
for i=1,120 do items[i]={jellyfin_id=string.format("id-%03d",i),title=string.format("Track %03d",i),artist="Artist"} end
local TestScreen = screen:new {
 create_ui=function(self)
  list_ui.create_root(self,"Tracks")
  list_ui.add_sort_control(self,{method="Title",direction="A-Z",fields={{id="title",label="Title"},{id="date_added",label="Date added"}}})
  self.virtual = virtual_list.create(self,items,{
   item_id=function(item) return item.jellyfin_id end,
   fixed_viewport=true,pool_size=7,anchor=4,motion_duration=90,total_count=#items,
   create_row=function(owner,item)
    return list_ui.add_track_row(owner,item,{detail=item.artist,artwork="//lua/img/cover_placeholder.png"})
   end,
   update_row=function(model,item,handlers)
    model:update(item,{detail=item.artist,on_click=handlers.on_click,on_long_press=handlers.on_long_press})
    model.on_click=handlers.on_click; model.on_long_press=handlers.on_long_press
   end,
  })
  self.first_row=self.sort_row.object
 end,
 on_show=function(self) list_ui.install_controls(self) end,
 on_hide=function(self) list_ui.restore_controls(self) end,
}
local s=TestScreen:new()
backstack.reset(s); backstack.flush(12)
local v=assert(s.virtual)
assert(v.fixed_viewport)
assert(v:pool_count()==7)
local cc=v.canvas:get_coords(); assert((cc.y2-cc.y1+1) == v.fixed_viewport_height)
assert(v:fixed_pool_height() > v.fixed_viewport_height)
assert(encoder_mode and type(_G.tangara_sim_encoder_event)=="function")
local function assert_bindings(start)
 local used={}
 for slot,m in ipairs(v.pool) do
  assert(m.virtual_slot==slot)
  assert(m.virtual_index==start+slot-1, string.format("slot %d index %s expected %d window=%s view=%s visible=%s",slot,tostring(m.virtual_index),start+slot-1,tostring(v.window_start),tostring(v.fixed_view_start),tostring(v:fixed_visible_count())))
  assert(not used[m.virtual_index]); used[m.virtual_index]=true
  local mc=m.object:get_coords(); local lc=v.motion_layer:get_coords(); local y=mc.y1-lc.y1
  assert(y==(slot-1)*v.row_stride,string.format("slot %d y %d",slot,y))
 end
end
local function assert_covered(label)
 local lc=v.canvas:get_coords(); local intervals={}
 for _,m in ipairs(v.pool) do
  local c=m.object:get_coords()
  if c.y2>=lc.y1 and c.y1<=lc.y2 then intervals[#intervals+1]={math.max(c.y1,lc.y1),math.min(c.y2,lc.y2)} end
 end
 table.sort(intervals,function(a,b)return a[1]<b[1] end)
 local cursor=lc.y1; local gap=0
 for _,r in ipairs(intervals) do if r[1]>cursor then gap=math.max(gap,r[1]-cursor) end; cursor=math.max(cursor,r[2]+1) end
 if cursor<=lc.y2 then gap=math.max(gap,lc.y2-cursor+1) end
 assert(gap<=v.row_gap+3,label.." gap="..gap)
end
assert_bindings(1)
assert_covered("initial boundary")
v:fixed_select(40, true)
assert(v.selected_index==40)
assert_bindings(v.window_start)
local ml=v.motion_layer:get_coords(); local cv=v.canvas:get_coords(); assert(ml.y1 <= cv.y1 and ml.y2 >= cv.y2)
assert_covered("forward start")
for i=1,6 do os.execute("sleep 0.02"); backstack.flush(2); assert_covered("forward frame "..i) end
v:fixed_select(13, true)
assert(v.selected_index==13)
assert_bindings(v.window_start)
assert_covered("reverse start")
for i=1,6 do os.execute("sleep 0.02"); backstack.flush(2); assert_covered("reverse frame "..i) end
v:fixed_select(14, true); v:fixed_select(13, true); v:fixed_select(31, true)
assert(v.selected_index==31)
assert_covered("interrupted")
assert(v:pool_count()==7)
v:fixed_select(1, true)
assert(v.selected_index==1)
assert_covered("top boundary")
v:fixed_select(2, true)
assert_covered("top boundary motion")
v:fixed_select(120, true)
assert(v.selected_index==120)
assert_covered("bottom boundary")
v:fixed_select(119, true)
assert(v.selected_index==119)
assert_covered("bottom reverse motion")
print("Fixed catalog viewport keeps seven stable rows and covers every animation frame")
os.exit(0)
