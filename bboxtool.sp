/**
 * TF2 Server-Side Bounding Box Drawer (Temp Entities)
 * Commands:
 *   sm_bboxme [me|all]
 *   sm_bboxentity [me|all]
 *   sm_bboxclear
 *   sm_bboxclear_all (admin)
 *
 * Cvars:
 *   sm_bbox_interval "0.051"  // seconds between redraws
 *   sm_bbox_life     "0.051"  // beam lifetime seconds
 *   sm_bbox_autoclear_on_round "1"
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <sdktools_tempents>
#include <sdktools_engine>
#include <sdktools_trace>

#define PLUGIN_NAME "TF2 TE BBox"
#define PLUGIN_VERSION "1.3.1"

int g_ColorBlue[4] = {0, 120, 255, 255};
int g_iLaserModel = -1;
int g_iHaloModel  = -1;

bool   g_bBBoxMeEnabled[MAXPLAYERS + 1];
bool   g_bBBoxMeBroadcast[MAXPLAYERS + 1];
Handle g_hMeTimer[MAXPLAYERS + 1];

ArrayList g_hEntityRefs[MAXPLAYERS + 1];
ArrayList g_hEntityTimers[MAXPLAYERS + 1];
ArrayList g_hEntityModes[MAXPLAYERS + 1];

ArrayList g_hProjRefs[MAXPLAYERS + 1];
ArrayList g_hProjTimers[MAXPLAYERS + 1];

// CVars
ConVar g_cvAutoClearOnRound;   // 1 = clear overlays on round start
ConVar g_cvInterval;           // seconds between re-emits (>=0.10)
ConVar g_cvLifeSec;            // TE beam life in seconds (>=0.10)

public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = "ChatGPT (lmfao)",
    description = "Draws server-side temp-entity bounding boxes",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_bboxme",        Cmd_BBoxMe,        "Toggle bbox for your player + your projectiles. Usage: sm_bboxme [me|all] if you use all, everyone on the server will see them.");
    RegConsoleCmd("sm_bboxentity",    Cmd_BBoxEntity,    "Toggle bbox on entity under crosshair. Usage: sm_bboxentity [me|all] if you use all, everyone on the server will see them.");
    RegConsoleCmd("sm_bboxclear",     Cmd_BBoxClear,     "Clear all bbox timers/refs for you and turn bboxme off.");
    RegAdminCmd( "sm_bboxclear_all",  Cmd_BBoxClearAll,  ADMFLAG_GENERIC, "ADMIN: Clear all bbox timers/refs for everyone and turn bboxme off.");

    g_cvAutoClearOnRound = CreateConVar("sm_bbox_autoclear_on_round", "1",   "Auto-clear all overlays on round start.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvInterval         = CreateConVar("sm_bbox_interval",           "0.051","Seconds between redraws.",       FCVAR_NOTIFY, true, 0.10, true, 0.50);
    g_cvLifeSec          = CreateConVar("sm_bbox_life",               "0.051","Beam lifetime in seconds.",      FCVAR_NOTIFY, true, 0.10, true, 0.50);

    HookEvent("teamplay_round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("arena_round_start",    Event_RoundStart, EventHookMode_PostNoCopy);

    for (int i = 1; i <= MaxClients; i++)
    {
        g_bBBoxMeEnabled[i] = false;
        g_bBBoxMeBroadcast[i] = false;
        g_hMeTimer[i] = null;

        g_hEntityRefs[i]   = new ArrayList();
        g_hEntityTimers[i] = new ArrayList();
        g_hEntityModes[i]  = new ArrayList();

        g_hProjRefs[i]     = new ArrayList();
        g_hProjTimers[i]   = new ArrayList();
    }
}

public void OnMapStart()
{
    g_iLaserModel = PrecacheModel("materials/sprites/laserbeam.vmt", true);
    if (g_iLaserModel <= 0) g_iLaserModel = PrecacheModel("materials/sprites/laser.vmt", true);
    g_iHaloModel  = PrecacheModel("materials/sprites/halo01.vmt", true);
}

public void OnPluginEnd()
{
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i)) ClearAllForClient(i);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvAutoClearOnRound.BoolValue) return;
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i)) ClearAllForClient(i);
}

public void OnClientDisconnect(int client) { ClearAllForClient(client); }

public void OnEntityDestroyed(int entity)
{
    if (entity <= 0) return;
    int ref = EntIndexToEntRef(entity);
    if (ref == INVALID_ENT_REFERENCE) return;

    for (int c = 1; c <= MaxClients; c++)
    {
        if (!IsClientInGame(c)) continue;

        ArrayList eRefs = g_hEntityRefs[c];
        ArrayList eTims = g_hEntityTimers[c];
        ArrayList eModes= g_hEntityModes[c];
        if (eRefs && eTims && eModes)
        {
            for (int i = eRefs.Length - 1; i >= 0; i--)
                if (eRefs.Get(i) == ref)
                {
                    Handle t = view_as<Handle>(eTims.Get(i));
                    if (t) CloseHandle(t);
                    eRefs.Erase(i); eTims.Erase(i); eModes.Erase(i);
                }
        }

        ArrayList pRefs = g_hProjRefs[c];
        ArrayList pTims = g_hProjTimers[c];
        if (pRefs && pTims)
        {
            for (int j = pRefs.Length - 1; j >= 0; j--)
                if (pRefs.Get(j) == ref)
                {
                    Handle t2 = view_as<Handle>(pTims.Get(j));
                    if (t2) CloseHandle(t2);
                    pRefs.Erase(j); pTims.Erase(j);
                }
        }
    }
}

/* ===== Commands ===== */

public Action Cmd_BBoxMe(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client)) { ReplyToCommand(client, "[bbox] You must be in-game."); return Plugin_Handled; }

    bool broadcast = g_bBBoxMeBroadcast[client];
    if (args >= 1)
    {
        char mode[8]; GetCmdArg(1, mode, sizeof(mode));
        if      (StrEqual(mode, "all", false)) broadcast = true;
        else if (StrEqual(mode, "me",  false)) broadcast = false;
        else { ReplyToCommand(client, "[bbox] Usage: sm_bboxme [me|all]"); return Plugin_Handled; }
    }

    if (!g_bBBoxMeEnabled[client])
    {
        g_bBBoxMeEnabled[client] = true;
        g_bBBoxMeBroadcast[client] = broadcast;

        if (g_hMeTimer[client] == null)
        {
            float dt = GetDrawInterval();
            g_hMeTimer[client] = CreateBBoxTimer(dt, Timer_DrawSelfBBox, client, EntIndexToEntRef(client), broadcast ? 1 : 0);
        }

        PrintToChat(client, "[bbox] bboxme: ON mode=%s (interval=%.3fs life=%.3fs).", broadcast ? "all" : "me", GetDrawInterval(), GetBeamLife());
    }
    else
    {
        if (args >= 1)
        {
            g_bBBoxMeBroadcast[client] = broadcast;
            PrintToChat(client, "[bbox] bboxme mode switched to %s.", broadcast ? "all" : "me");
        }
        else
        {
            DisableBBoxMe(client);
            PrintToChat(client, "[bbox] bboxme: OFF.");
        }
    }
    return Plugin_Handled;
}

public Action Cmd_BBoxEntity(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client)) { ReplyToCommand(client, "[bbox] You must be in-game."); return Plugin_Handled; }

    int broadcast = 0;
    if (args >= 1)
    {
        char mode[8]; GetCmdArg(1, mode, sizeof(mode));
        if      (StrEqual(mode, "all", false)) broadcast = 1;
        else if (StrEqual(mode, "me",  false)) broadcast = 0;
        else { ReplyToCommand(client, "[bbox] Usage: sm_bboxentity [me|all]"); return Plugin_Handled; }
    }

    int ent = TraceLookEntity(client);
    if (!IsValidEntity(ent)) { PrintToChat(client, "[bbox] No valid target under crosshair."); return Plugin_Handled; }

    int ref = EntIndexToEntRef(ent);
    if (ref == INVALID_ENT_REFERENCE) { PrintToChat(client, "[bbox] Invalid entity reference."); return Plugin_Handled; }

    int idx = FindRefIndex(g_hEntityRefs[client], ref);
    if (idx >= 0)
    {
        Handle t = view_as<Handle>(g_hEntityTimers[client].Get(idx));
        if (t) CloseHandle(t);
        g_hEntityTimers[client].Erase(idx);
        g_hEntityRefs[client].Erase(idx);
        g_hEntityModes[client].Erase(idx);
        PrintToChat(client, "[bbox] bboxentity: OFF for that target.");
    }
    else
    {
        float dt = GetDrawInterval();
        Handle timer = CreateBBoxTimer(dt, Timer_DrawBBoxEntity, client, ref, broadcast);
        if (timer == null) { PrintToChat(client, "[bbox] Failed to start draw timer."); return Plugin_Handled; }
        g_hEntityRefs[client].Push(ref);
        g_hEntityTimers[client].Push(timer);
        g_hEntityModes[client].Push(broadcast);
        PrintToChat(client, "[bbox] bboxentity: ON mode=%s.", (broadcast == 1) ? "all" : "me");
    }
    return Plugin_Handled;
}

public Action Cmd_BBoxClear(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client)) { ReplyToCommand(client, "[bbox] You must be in-game."); return Plugin_Handled; }
    ClearAllForClient(client);
    PrintToChat(client, "[bbox] All overlays cleared and bboxme disabled for you.");
    return Plugin_Handled;
}

public Action Cmd_BBoxClearAll(int client, int args)
{
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i)) ClearAllForClient(i);
    ReplyToCommand(client, "[bbox] Cleared all overlays for everyone.");
    return Plugin_Handled;
}

/* ===== Clear helpers ===== */

void ClearAllForClient(int client)
{
    DisableBBoxMe(client);
    ClearEntityToggles(client);
    ClearProjectiles(client);
}

void DisableBBoxMe(int client)
{
    g_bBBoxMeEnabled[client] = false;
    if (g_hMeTimer[client] != null) { CloseHandle(g_hMeTimer[client]); g_hMeTimer[client] = null; }
}

void ClearProjectiles(int client)
{
    if (g_hProjRefs[client] && g_hProjTimers[client])
    {
        for (int i = 0; i < g_hProjTimers[client].Length; i++)
        {
            Handle t = view_as<Handle>(g_hProjTimers[client].Get(i));
            if (t) CloseHandle(t);
        }
        g_hProjRefs[client].Clear();
        g_hProjTimers[client].Clear();
    }
}

void ClearEntityToggles(int client)
{
    if (g_hEntityTimers[client] && g_hEntityRefs[client] && g_hEntityModes[client])
    {
        for (int i = 0; i < g_hEntityTimers[client].Length; i++)
        {
            Handle t = view_as<Handle>(g_hEntityTimers[client].Get(i));
            if (t) CloseHandle(t);
        }
        g_hEntityRefs[client].Clear();
        g_hEntityTimers[client].Clear();
        g_hEntityModes[client].Clear();
    }
}

/* ===== Projectiles (bboxme) ===== */

public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrContains(classname, "tf_projectile_", false) != 0) return;
    SDKHook(entity, SDKHook_SpawnPost, OnProjSpawned);
}

public void OnProjSpawned(int entity)
{
    if (!IsValidEntity(entity)) return;

    int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
    if (owner < 1 || owner > MaxClients || !IsClientInGame(owner)) return;
    if (!g_bBBoxMeEnabled[owner]) return;

    int ref = EntIndexToEntRef(entity);
    if (ref == INVALID_ENT_REFERENCE) return;

    float dt = GetDrawInterval();
    Handle timer = CreateBBoxTimer(dt, Timer_DrawProjBBox, owner, ref, 0);
    if (timer == null) return;

    g_hProjRefs[owner].Push(ref);
    g_hProjTimers[owner].Push(timer);
}

/* ===== Timers ===== */

Handle CreateBBoxTimer(float interval, Timer func, int client, int entref, int broadcastFlag)
{
    DataPack dp = new DataPack();
    dp.WriteCell(client);
    dp.WriteCell(entref);
    dp.WriteCell(broadcastFlag); // 0=me, 1=all (bboxme projectiles ignore; use current g_bBBoxMeBroadcast)
    return CreateTimer(interval, func, dp, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_DrawSelfBBox(Handle timer, any data)
{
    DataPack dp = view_as<DataPack>(data); dp.Reset();
    int client = dp.ReadCell(); int ref = dp.ReadCell(); dp.ReadCell();

    if (client <= 0 || !IsClientInGame(client) || !g_bBBoxMeEnabled[client]) { delete dp; return Plugin_Stop; }
    int ent = EntRefToEntIndex(ref);
    if (ent != client || !IsValidEntity(ent)) { delete dp; return Plugin_Stop; }

    DrawEntityOBB(ent, g_bBBoxMeBroadcast[client] ? -1 : client);
    return Plugin_Continue;
}

public Action Timer_DrawProjBBox(Handle timer, any data)
{
    DataPack dp = view_as<DataPack>(data); dp.Reset();
    int client = dp.ReadCell(); int ref = dp.ReadCell(); dp.ReadCell();

    if (client <= 0 || !IsClientInGame(client) || !g_bBBoxMeEnabled[client]) { delete dp; return Plugin_Stop; }
    int ent = EntRefToEntIndex(ref);
    if (!IsValidEntity(ent)) { delete dp; return Plugin_Stop; }

    DrawEntityOBB(ent, g_bBBoxMeBroadcast[client] ? -1 : client);
    return Plugin_Continue;
}

public Action Timer_DrawBBoxEntity(Handle timer, any data)
{
    DataPack dp = view_as<DataPack>(data); dp.Reset();
    int client = dp.ReadCell(); int ref = dp.ReadCell(); int bcast = dp.ReadCell();

    if (client <= 0 || !IsClientInGame(client)) { delete dp; return Plugin_Stop; }
    int ent = EntRefToEntIndex(ref);
    if (!IsValidEntity(ent)) { delete dp; return Plugin_Stop; }

    DrawEntityOBB(ent, (bcast == 1) ? -1 : client);
    return Plugin_Continue;
}

/* ===== Drawing helpers ===== */

float GetDrawInterval() { return g_cvInterval.FloatValue; }

float GetBeamLife()
{
    float s = g_cvLifeSec.FloatValue;
    if (s < 0.051) s = 0.051; // Must be a minimum of 0.050 or the temp entities become permanent.
    return s;
}

void DrawEntityOBB(int ent, int target)
{
    float origin[3], angles[3], mins[3], maxs[3];
    if (!GetEntWorldSpace(ent, origin, angles)) return;
    if (!GetCollisionBounds(ent, mins, maxs))   return;

    float fwd[3], right[3], up[3];
    GetAngleVectors(angles, fwd, right, up);

    float c[8][3];  MakeCorners(mins, maxs, c);
    float w[8][3];  for (int i = 0; i < 8; i++) LocalToWorld(origin, fwd, right, up, c[i], w[i]);

    DrawEdge(w[0], w[1], target); DrawEdge(w[1], w[3], target);
    DrawEdge(w[3], w[2], target); DrawEdge(w[2], w[0], target);

    DrawEdge(w[4], w[5], target); DrawEdge(w[5], w[7], target);
    DrawEdge(w[7], w[6], target); DrawEdge(w[6], w[4], target);

    DrawEdge(w[0], w[4], target); DrawEdge(w[1], w[5], target);
    DrawEdge(w[2], w[6], target); DrawEdge(w[3], w[7], target);
}

bool GetEntWorldSpace(int ent, float origin[3], float angles[3])
{
    bool ok = false;
    if (HasEntProp(ent, Prop_Data, "m_angAbsRotation")) { GetEntPropVector(ent, Prop_Data, "m_angAbsRotation", angles); ok = true; }
    else if (HasEntProp(ent, Prop_Data, "m_angRotation")) { GetEntPropVector(ent, Prop_Data, "m_angRotation", angles); ok = true; }

    if (HasEntProp(ent, Prop_Send, "m_vecOrigin")) { GetEntPropVector(ent, Prop_Send, "m_vecOrigin", origin); ok = true; }
    else if (HasEntProp(ent, Prop_Data, "m_vecAbsOrigin")) { GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", origin); ok = true; }

    return ok;
}

bool GetCollisionBounds(int ent, float mins[3], float maxs[3])
{
    if (HasEntProp(ent, Prop_Send, "m_vecMins") && HasEntProp(ent, Prop_Send, "m_vecMaxs"))
    { GetEntPropVector(ent, Prop_Send, "m_vecMins", mins); GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs); return true; }
    if (HasEntProp(ent, Prop_Data, "m_vecMins") && HasEntProp(ent, Prop_Data, "m_vecMaxs"))
    { GetEntPropVector(ent, Prop_Data, "m_vecMins", mins); GetEntPropVector(ent, Prop_Data, "m_vecMaxs", maxs); return true; }
    return false;
}

void MakeCorners(const float mins[3], const float maxs[3], float outCorners[8][3])
{
    int k = 0;
    for (int iz = 0; iz < 2; iz++)
    for (int iy = 0; iy < 2; iy++)
    for (int ix = 0; ix < 2; ix++)
    {
        outCorners[k][0] = (ix == 0) ? mins[0] : maxs[0];
        outCorners[k][1] = (iy == 0) ? mins[1] : maxs[1];
        outCorners[k][2] = (iz == 0) ? mins[2] : maxs[2];
        k++;
    }
}

void LocalToWorld(const float origin[3], const float fwd[3], const float right[3], const float up[3], const float local[3], float world[3])
{
    world[0] = origin[0] + fwd[0]*local[0] + right[0]*local[1] + up[0]*local[2];
    world[1] = origin[1] + fwd[1]*local[0] + right[1]*local[1] + up[1]*local[2];
    world[2] = origin[2] + fwd[2]*local[0] + right[2]*local[1] + up[2]*local[2];
}

void DrawEdge(const float a[3], const float b[3], int target)
{
    float life = GetBeamLife();
    // amplitude (before color) = 0
    TE_SetupBeamPoints(a, b, g_iLaserModel, g_iHaloModel, 0, 0, life, 1.0, 1.0, 0, 0.0, g_ColorBlue, 0);
    if (target == -1) TE_SendToAll(); else TE_SendToClient(target);
}

/* ===== Trace ===== */

int TraceLookEntity(int client)
{
    float eye[3], ang[3], dir[3], end[3];
    GetClientEyePosition(client, eye);
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);

    end[0] = eye[0] + dir[0] * 8192.0;
    end[1] = eye[1] + dir[1] * 8192.0;
    end[2] = eye[2] + dir[2] * 8192.0;

    TR_TraceRayFilter(eye, end, MASK_SOLID|MASK_SHOT, RayType_EndPoint, TraceFilterSkipSelf, client);
    return TR_GetEntityIndex();
}

public bool TraceFilterSkipSelf(int entity, int contentsMask, any data)
{
    int self = view_as<int>(data);
    if (entity == self) return false;
    return true;
}

int FindRefIndex(ArrayList refs, int entref)
{
    if (!refs) return -1;
    for (int i = 0; i < refs.Length; i++)
        if (refs.Get(i) == entref) return i;
    return -1;
}
