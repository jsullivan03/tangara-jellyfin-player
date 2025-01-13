-- SPDX-FileCopyrightText: 2023 jacqueline <me@jacqueline.id.au>
--
-- SPDX-License-Identifier: GPL-3.0-only

local backstack = require("backstack")
local widgets = require("widgets")
local font = require("font")
local styles = require("styles")
local screen = require("screen")
local lvgl = require("lvgl")

local function show_license(text)
  backstack.push(widgets.MenuScreen:new {
    show_back = true,
    title = "Licenses",
    create_ui = function(self)
      widgets.MenuScreen.create_ui(self)
      -- Licenses are all longer than one screen, so we need to be able to
      -- scroll to read all the text.  Break up the content by line, and
      -- insert an object after each line that the user can scroll to.
      for line in text:gmatch("[^\r\n]+") do
        self.root:Label {
          w = lvgl.PCT(100),
          h = lvgl.SIZE_CONTENT,
          text_font = font.fusion_10,
          text = line,
        }
        local scroller = self.root:Object { w = 1, h = 1 }
        scroller:onevent(lvgl.EVENT.FOCUSED, function()
          scroller:scroll_to_view(1)
        end)
        lvgl.group.get_default():add_obj(scroller)
      end
    end
  })
end

-- Note: if a line of text in a license is much longer than 240 characters, it
-- won't fit on the screen, so we split lines around that point.

local function gpl(copyright)
  show_license(copyright .. [[

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.
This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
You should have received a copy of the GNU General Public License along with this program; if not, write to the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.]])
end

local function lgpl(copyright)
  show_license(copyright .. [[

 This library is free software; you can redistribute it and/or modify it under the terms of the GNU Lesser General Public License as published by the Free Software Foundation; either version 2.1 of the License, or (at your option) any later version.
This library is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.
You should have received a copy of the GNU Lesser General Public License along with this library; if not, write to the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.]])
end

local function bsd(copyright)
  show_license(copyright .. [[

Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted.
THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT,
OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.]])
end

local function xiphbsd(copyright)
  show_license(copyright .. [[

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
- Neither the name of the Xiph.org Foundation nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.]])
end

local function apache(copyright)
  show_license(copyright .. [[

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at
   http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific
language governing permissions and limitations under the License.]])
end

local function mit(copyright)
  show_license(copyright .. [[

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.]])
end

local function ofl(copyright)
  show_license(copyright .. [[

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide development of collaborative font projects, to support the font creation efforts of academic and linguistic communities, and to provide a free and open framework in which fonts may be shared and improved in partnership with others.
The OFL allows the licensed fonts to be used, studied, modified and redistributed freely as long as they are not sold by themselves. The fonts, including any derivative works, can be bundled, embedded, redistributed and/or sold with any
software provided that any reserved names are not used by derivative works. The fonts and derivatives, however, cannot be released under any other type of license. The requirement for fonts to remain under this license does not apply to any document created using the fonts or their derivatives.
DEFINITIONS
"Font Software" refers to the set of files released by the Copyright Holder(s) under this license and clearly marked as such. This may include source files, build scripts and documentation.
"Reserved Font Name" refers to any names specified as such after the copyright statement(s).
"Original Version" refers to the collection of Font Software components as distributed by the Copyright Holder(s).
"Modified Version" refers to any derivative made by adding to, deleting, or substituting — in part or in whole — any of the components of the Original Version, by changing formats or by porting the Font Software to a new environment.
"Author" refers to any designer, engineer, programmer, technical writer or other person who contributed to the Font Software.
PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining a copy of the Font Software, to use, study, copy, merge, embed, modify, redistribute, and sell modified and unmodified copies of the Font Software, subject to the following conditions:
1) Neither the Font Software nor any of its individual components, in Original or Modified Versions, may be sold by itself.
2) Original or Modified Versions of the Font Software may be bundled, redistributed and/or sold with any software, provided that each copy contains the above copyright notice and this license. These can be included either as stand-alone
text files, human-readable headers or in the appropriate machine-readable metadata fields within text or binary files as long as those fields can be easily viewed by the user.
3) No Modified Version of the Font Software may use the Reserved Font Name(s) unless explicit written permission is granted by the corresponding Copyright Holder. This restriction only applies to the primary font name as presented to the users.
4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font Software shall not be used to promote, endorse or advertise any Modified Version, except to acknowledge the contribution(s) of the Copyright Holder(s) and the Author(s) or with their explicit written permission.
5) The Font Software, modified or unmodified, in part or in whole, must be distributed entirely under this license, and must not be distributed under any other license. The requirement for fonts to remain under this license does not apply to any document created using the Font Software.
TERMINATION
This license becomes null and void if any of the above conditions are not met.
DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF COPYRIGHT, PATENT, TRADEMARK,
OR OTHER RIGHT. IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM OTHER DEALINGS IN THE FONT SOFTWARE.]])
end

local function unlicense(copyright)
  show_license(copyright .. [[

This is free and unencumbered software released into the public domain.
Anyone is free to copy, modify, publish, use, compile, sell, or distribute this software, either in source code form or as a compiled binary, for any purpose, commercial or non-commercial, and by any means.
In jurisdictions that recognize copyright laws, the author or authors of this software dedicate any and all copyright interest in the software to the public domain. We make this dedication for the benefit of the public at large and to the
detriment of our heirs and successors. We intend this dedication to be an overt act of relinquishment in perpetuity of all present and future rights to this software under copyright law.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
For more information, please refer to <http://unlicense.org/>]])
end

local function bsl(copyright)
  show_license(copyright .. [[

Permission is hereby granted, free of charge, to any person or organization obtaining a copy of the software and accompanying documentation covered by this license (the "Software") to use, reproduce, display, distribute, execute, and
transmit the Software, and to prepare derivative works of the Software, and to permit third-parties to whom the Software is furnished to do so, all subject to the following:
The copyright notices in the Software and this entire statement, including the above license grant, this restriction and the following disclaimer, must be included in all copies of the Software, in whole or in part, and all derivative
works of the Software, unless such copies or derivative works are solely in the form of machine-executable object code generated by a source language processor.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.]])
end

return function(self)
  local container = self.content:Object {
    flex = {
      flex_direction = "column",
      flex_wrap = "nowrap",
      justify_content = "flex-start",
      align_items = "flex-start",
      align_content = "flex-start",
    },
    w = lvgl.PCT(100),
    h = lvgl.SIZE_CONTENT,
  }

  local function library(name, license, show_fn)
    local row = container:Object {
      flex = {
        flex_direction = "row",
        justify_content = "flex-start",
        align_items = "flex-start",
        align_content = "flex-start",
      },
      w = lvgl.PCT(100),
      h = lvgl.SIZE_CONTENT,
    }
    row:add_style(styles.list_item)
    row:Label { text = name, flex_grow = 1 }
    local button = row:Button {}
    button:Label { text = license, text_font = font.fusion_10 }
    button:onClicked(show_fn)
  end

  library("catch2", "BSL", function()
    bsl("2022 Two Blue Cubes Ltd.")
  end)
  library("CBOR", "MIT", function()
    mit("2017 Intel Corporation")
  end)
  library("DRFLAC", "Unlicense", function()
    unlicense("2023 David Reid")
  end)
  library("ESP-IDF", "Apache 2.0", function()
    apache("2015-2024 Espressif Systems (Shanghai) CO LTD")
  end)
  library("esp-idf-lua", "MIT", function()
    mit("Copyright (C) 2019 Ruslan V. Uss")
  end)
  library("FatFs", "BSD", function()
    bsd("Copyright (C) 2022, ChaN, all right reserved.")
  end)
  library("Fusion font", "OFL", function()
    ofl("Copyright (C) 2022 TakWolf")
  end)
  library("komihash", "MIT", function()
    mit("Copyright (c) 2021-2022 Aleksey Vaneev")
  end)
  library("LevelDB", "BSD", function()
    bsd("Copyright (c) 2011 The LevelDB Authors. All rights reserved.")
  end)
  library("libcppbor", "Apache 2.0", function()
    apache("Copyright 2019 Google LLC")
  end)
  library("libmad", "GPL", function()
    gpl("Copyright (C) 2000-2004 Underbit Technologies, Inc.")
  end)
  library("libtags", "MIT", function()
    mit("Copyright © 2013-2020 Sigrid Solveig Haflínudóttir")
  end)
  library("locale", "LGPL", function()
    lgpl("1996-2018 Free Software Foundation, Inc.")
  end)
  library("Lua", "MIT", function()
    mit("Copyright (C) 1994-2018 Lua.org, PUC-Rio")
  end)
  library("lua-linenoise", "MIT", function()
    mit("Copyright (c) 2011-2015 Rob Hoelz <rob@hoelz.ro>")
  end)
  library("lua-repl", "MIT", function()
    mit("Copyright (c) 2011-2015 Rob Hoelz <rob@hoelzro.net>")
  end)
  library("lua-term", "MIT", function()
    mit("Copyright (c) 2009 Rob Hoelz <rob@hoelzro.net>")
  end)
  library("luavgl", "MIT", function()
    mit("Copyright (c) 2022 Neo Xu")
  end)
  library("LVGL", "MIT", function()
    mit("Copyright (c) 2021 LVGL Kft")
  end)
  library("MillerShuffle", "Apache 2.0", function()
    apache("Copyright 2022 Ronald Ross Miller")
  end)
  library("ogg", "BSD", function()
    xiphbsd("Copyright (c) 2002, Xiph.org Foundation")
  end)
  library("Opus", "BSD", function()
    xiphbsd(
      "Copyright 2001-2011 Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo")
  end)
  library("Opusfile", "BSD", function()
    xiphbsd("Copyright (c) 1994-2013 Xiph.Org Foundation and contributors")
  end)
  library("result", "MIT", function()
    mit("Copyright (c) 2017-2021 Matthew Rodusek")
  end)
  library("speexdsp", "BSD", function()
    xiphbsd(
      "Copyright 2002-2008 Xiph.org Foundation, Copyright 2002-2008 Jean-Marc Valin, Copyright 2005-2007 Analog Devices Inc., Copyright 2005-2008	Commonwealth Scientific and Industrial Research, Organisation (CSIRO), Copyright 1993, 2002, 2006 David Rowe, Copyright 2003 EpicGames, Copyright 1992-1994	Jutta Degener, Carsten Bormann")
  end)
  library("tinyfsm", "MIT", function()
    mit("Copyright (c) 2012-2022 Axel Burri")
  end)
  library("tremor", "BSD", function()
    xiphbsd("Copyright (c) 2002, Xiph.org Foundation")
  end)
end
