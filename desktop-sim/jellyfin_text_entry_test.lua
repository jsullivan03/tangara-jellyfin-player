package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
lvgl.ImgData = function(path)
    return path
end

_G.tangara_sim_enable_encoder_handler = true
require("mocks").install(lvgl)

local popped = 0
package.loaded["backstack"] = {
    pop = function()
        popped = popped + 1
    end,
    push = function()
    end,
}

for _, name in ipairs({
    "jellyfin_marquee",
    "jellyfin_list_ui",
    "jellyfin_text_entry",
}) do
    package.loaded[name] = nil
end

local submitted = nil
local text_entry = require("jellyfin_text_entry")
local page = text_entry.new {
    title = "New playlist",
    initial_value = "Mix",
    on_submit = function(value)
        submitted = value
        return true
    end,
}

page:create_ui()
page:on_show()

local initial_state =
    page:text_entry_state()

assert(
    initial_state.value == "Mix" and
        initial_state.token == "a" and
        initial_state.previous_two_token == "!" and
        initial_state.previous_token == "?" and
        initial_state.next_token == "b" and
        initial_state.next_two_token == "c" and
        initial_state.caps_locked == false and
        initial_state.carousel == true and
        initial_state.carousel_active == false and
        initial_state.hint_visible == false and
        initial_state.cancel_action_visible == false and
        #initial_state.actions == 4 and
        initial_state.actions[1] == "caps" and
        initial_state.actions[2] == "space" and
        initial_state.actions[3] == "backspace" and
        initial_state.actions[4] == "confirm" and
        initial_state.action_icons.space ==
            "underscore" and
        initial_state.action_icons
                .backspace_max_thickness == 1 and
        initial_state.action_icons
                .confirm_max_thickness == 1,
    "Text entry did not default to lowercase with the refined action controls"
)

assert(
    initial_state.carousel_positions.current == 78 and
        initial_state.carousel_positions.current -
            initial_state.carousel_positions.previous == 25 and
        initial_state.carousel_positions.next -
            initial_state.carousel_positions.current == 25 and
        initial_state.carousel_positions.previous -
            initial_state.carousel_positions.previous_two == 25 and
        initial_state.carousel_positions.next_two -
            initial_state.carousel_positions.next == 25,
    "Text entry carousel is not symmetrically centered"
)

local letter_count = 0
local saw_exclamation = false
local saw_question = false
for _, token in ipairs(text_entry.tokens) do
    assert(
        token.action == nil and
            token.value ~= nil,
        "Space, backspace, confirm, or cancel leaked into the character carousel"
    )

    if token.kind == "letter" then
        letter_count = letter_count + 1
        assert(
            token.value == token.value:lower(),
            "The alphabet is duplicated instead of using Caps"
        )
    elseif token.value == "!" then
        saw_exclamation = true
    elseif token.value == "?" then
        saw_question = true
    end
end

assert(
    letter_count == 26 and
        saw_exclamation and
        saw_question,
    "Text carousel does not contain one alphabet plus ! and ?"
)

for _ = 1, 150 do
    page:rotate(1)
end

local fast_state =
    page:text_entry_state()
assert(
    fast_state.previous_two_token ~= nil and
        fast_state.previous_token ~= nil and
        fast_state.token ~= nil and
        fast_state.next_token ~= nil and
        fast_state.next_two_token ~= nil,
    "Fast carousel rotation left an incomplete five-character view"
)

-- First press enters the character carousel instead of immediately typing.
page.token_row.on_click()
assert(
    page:text_entry_state().carousel_active == true,
    "Pressing the carousel did not capture rotary input"
)

assert(page:set_token("a"))
page.token_row.on_click()
assert(
    page:text_entry_state().value == "Mixa" and
        page:text_entry_state().caps_locked == false,
    "Lowercase selection did not use the shared alphabet with Caps off"
)

page.caps_button.on_click()
assert(
    page:text_entry_state().caps_locked == true and
        page:text_entry_state().token == "A",
    "Caps control did not change the visible carousel case"
)

-- Back first releases the carousel; a later Back can leave the screen.
page.go_back()
assert(
    page:text_entry_state().carousel_active == false and
        popped == 0,
    "Back did not release the carousel before cancelling text entry"
)

page.backspace_button.on_click()
assert(
    page:text_entry_state().value == "Mix",
    "Dedicated backspace button did not remove the final character"
)

page.space_button.on_click()
assert(page:set_token("2"))
page:enter_carousel()
page.token_row.on_click()
page:leave_carousel()
page.confirm_button.on_click()

assert(
    submitted == "Mix 2" and
        popped == 1,
    "Dedicated confirm button did not submit the completed playlist name"
)

page:on_hide()

print(
    "Rotary text entry defaults to lowercase and uses refined Caps, space, backspace, and confirm controls"
)
os.exit(0)
