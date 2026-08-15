#ifndef TANGARA_SIM_AUDIO_H
#define TANGARA_SIM_AUDIO_H

#include <lua.h>

int luaopen_sim_audio(lua_State *L);
void sim_audio_shutdown(void);

#endif
