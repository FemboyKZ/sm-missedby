#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <cstrike>
#include <regex>
#include <topmenus>
#include <clientprefs>
#include <gokz/core>
#include <movement>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name        = "FKZ Miss Helper",
    author      = "jvnipers",
    description = "Create and manage zones that display how much you missed a jump by.",
    version     = "1.0.3",
    url         = "https://github.com/FemboyKZ/sm-missedby"
};

#define MAX_ZONES            512
#define STEAMID_LEN          32
#define MAX_NAME_LEN         64
#define DEFAULTS_PATH        "configs/missedby.cfg"

// Source engine ground epsilon: player origin sits exactly this far above the surface.
// threshold_z = surface_hit_z (or abs_origin_z) - GROUND_EPSILON = actual floor level.
#define GROUND_EPSILON       0.03125

// Placement modes for the zone setup menu
#define PLACE_MODE_SNAP_GRID 0    // crosshair hit rounded to the nearest whole hammer unit
#define PLACE_MODE_SNAP      1    // find nearest surface edge in any direction, then snap to nearby wall
#define PLACE_MODE_PRECISE   2    // exact crosshair hit point
#define PLACE_MODE_FEET      3    // player's current foot position (GetClientAbsOrigin)

// Snap-mode tuning
#define EDGE_PROBE_DIST      8.0      // probe ray half-length perpendicular to surface
#define EDGE_SEARCH_DIST     512.0    // max distance along surface to search for an edge
#define EDGE_ITERATIONS      20       // binary search steps
#define SNAP_DIRS            16       // radial sample count for nearest-edge search
#define SNAP_WALL_DIST       8.0      // snap to wall if wall face is within this distance
#define NORMAL_DOT_MIN       0.95     // cos ~18 deg - surface must match this closely

// Workspace cross marker
#define WS_CROSS_SIZE        8.0     // half-width of the X marker in world units
#define WS_CROSS_LIFE        0.97    // beam life slightly under the 1s repeat interval

// ===== Zone store =====

int       g_iZoneId[MAX_ZONES];
char      g_sZoneName[MAX_ZONES][MAX_NAME_LEN];
float     g_fZoneP0[MAX_ZONES][2];
float     g_fZoneP1[MAX_ZONES][2];
float     g_fZoneP2[MAX_ZONES][2];
float     g_fZoneThreshZ[MAX_ZONES];
bool      g_bZoneHasP2[MAX_ZONES];
bool      g_bZoneThreshDown[MAX_ZONES];
bool      g_bZoneIsDefault[MAX_ZONES];
int       g_iZoneOwner[MAX_ZONES];    // client slot owning this zone, -1 = default
char      g_sZoneOwnerSteamId[MAX_ZONES][STEAMID_LEN];
int       g_iZoneCount;

// ===== Cookies =====
Handle    g_hCookieEnable;

// Per-client list of zone DB ids the player has turned off.
// Every zone visible to a player (defaults + their own) is active unless its id
// appears here. Keyed by id so it survives slot reindexing and map reloads.
ArrayList g_hDisabledZones[MAXPLAYERS + 1];

// ===== Per-client state =====
bool      g_bEnable[MAXPLAYERS + 1];
bool      g_bOldDuck[MAXPLAYERS + 1];
float     g_fStartOrigin[MAXPLAYERS + 1][3];
float     g_fEndOrigin[MAXPLAYERS + 1][3];

// Zone setup workspace
float     g_fWsP0[MAXPLAYERS + 1][2];
float     g_fWsP1[MAXPLAYERS + 1][2];
float     g_fWsP2[MAXPLAYERS + 1][2];
float     g_fWsThreshZ[MAXPLAYERS + 1];
bool      g_bWsThreshDown[MAXPLAYERS + 1];
bool      g_bWsInProgress[MAXPLAYERS + 1];
bool      g_bAwaitingName[MAXPLAYERS + 1];
int       g_iPlaceMode[MAXPLAYERS + 1];    // PLACE_MODE_SNAP_GRID, _SNAP, _PRECISE, or _FEET

// Workspace cross markers - indices: 0=p0, 1=p1, 2=p2, 3=threshz
float     g_fWsPos3D[MAXPLAYERS + 1][4][3];
bool      g_bWsPosSet[MAXPLAYERS + 1][4];
Handle    g_hWsCrossTimer[MAXPLAYERS + 1];

// ===== DB =====
enum DatabaseType
{
    DatabaseType_SQLite = 0,
    DatabaseType_MySQL,
};

Database     g_hDB;
bool         g_bDbReady;
DatabaseType g_eDbType;

int          g_iBeamModel;

// ===== Lifecycle =====
public void OnPluginStart()
{
    RegConsoleCmd("sm_missedby", CmdMissedBy);
    RegConsoleCmd("sm_miss", CmdMissedBy);
    RegConsoleCmd("sm_miss_export", CmdExportZone);
    RegConsoleCmd("sm_miss_import", CmdImportZone);

    AddCommandListener(CmdSayListener, "say");
    AddCommandListener(CmdSayListener, "say_team");

    g_hCookieEnable = RegClientCookie("missedby_enable", "Jump Missedby Helper enabled state", CookieAccess_Private);

    DB_Connect();
}

public void OnClientCookiesCached(int client)
{
    char val[4];
    GetClientCookie(client, g_hCookieEnable, val, sizeof(val));
    // Enabled by default. Cookie only ever stores an explicit "0" opt-out.
    g_bEnable[client] = !StrEqual(val, "0");
}

public void OnMapStart()
{
    g_iBeamModel = PrecacheModel("materials/sprites/laserbeam.vmt", true);
    g_iZoneCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        g_hWsCrossTimer[i] = null;
        g_bWsInProgress[i] = false;
        for (int j = 0; j < 4; j++)
            g_bWsPosSet[i][j] = false;
    }

    if (g_bDbReady)
        DB_LoadDefaults();
}

public void OnClientPutInServer(int client)
{
    if (AreClientCookiesCached(client))
    {
        char val[4];
        GetClientCookie(client, g_hCookieEnable, val, sizeof(val));
        // Enabled by default. Cookie only ever stores an explicit "0" opt-out.
        g_bEnable[client] = !StrEqual(val, "0");
    }
    else
    {
        g_bEnable[client] = true;
    }
    delete g_hDisabledZones[client];
    g_hDisabledZones[client] = new ArrayList();
    g_bWsInProgress[client]  = false;
    g_bAwaitingName[client]  = false;
    g_iPlaceMode[client]     = PLACE_MODE_SNAP_GRID;
    g_bWsThreshDown[client]  = true;
    g_hWsCrossTimer[client]  = null;
    for (int i = 0; i < 4; i++)
        g_bWsPosSet[client][i] = false;
}

public void OnClientPostAdminCheck(int client)
{
    if (g_bDbReady && !IsFakeClient(client))
        DB_LoadPlayerZones(client);
}

public void OnClientDisconnect(int client)
{
    delete g_hWsCrossTimer[client];
    delete g_hDisabledZones[client];
    RemoveClientZones(client);
}

// ===== Database =====

void DB_Connect()
{
    char error[255];
    g_hDB = SQL_Connect("missedby", true, error, sizeof(error));
    if (g_hDB == null)
    {
        LogError("DB connect failed: %s", error);
        return;
    }

    char driver[8];
    SQL_ReadDriver(g_hDB, driver, sizeof(driver));
    if (StrEqual(driver, "mysql", false))
    {
        g_eDbType = DatabaseType_MySQL;
        SQL_SetCharset(g_hDB, "utf8mb4");
    }
    else
    {
        g_eDbType = DatabaseType_SQLite;
    }

    g_bDbReady = true;
    DB_CreateTable();
}

void DB_CreateTable()
{
    if (g_eDbType == DatabaseType_MySQL)
    {
        g_hDB.Query(DB_OnCreateTable,
                    "CREATE TABLE IF NOT EXISTS Zones ( \
			    id          INT          NOT NULL AUTO_INCREMENT, \
			    map         VARCHAR(255) NOT NULL, \
			    name        VARCHAR(255) NOT NULL, \
			    steam_id    VARCHAR(32)  NOT NULL DEFAULT '', \
			    point0_x    FLOAT        NOT NULL DEFAULT 0, \
			    point0_y    FLOAT        NOT NULL DEFAULT 0, \
			    point1_x    FLOAT        NOT NULL DEFAULT 0, \
			    point1_y    FLOAT        NOT NULL DEFAULT 0, \
			    point2_x    FLOAT        NOT NULL DEFAULT 0, \
			    point2_y    FLOAT        NOT NULL DEFAULT 0, \
			    threshold_z  FLOAT        NOT NULL DEFAULT 0, \
			    has_p2       INT          NOT NULL DEFAULT 1, \
			    thresh_down  INT          NOT NULL DEFAULT 1, \
			    is_default   INT          NOT NULL DEFAULT 0, \
			    PRIMARY KEY (id), \
			    UNIQUE KEY uk_map_name (map, steam_id, name))");
    }
    else
    {
        g_hDB.Query(DB_OnCreateTable,
                    "CREATE TABLE IF NOT EXISTS Zones ( \
			    id          INTEGER PRIMARY KEY AUTOINCREMENT, \
			    map         TEXT    NOT NULL, \
			    name        TEXT    NOT NULL, \
			    steam_id    TEXT    NOT NULL DEFAULT '', \
			    point0_x    REAL    NOT NULL DEFAULT 0, \
			    point0_y    REAL    NOT NULL DEFAULT 0, \
			    point1_x    REAL    NOT NULL DEFAULT 0, \
			    point1_y    REAL    NOT NULL DEFAULT 0, \
			    point2_x    REAL    NOT NULL DEFAULT 0, \
			    point2_y    REAL    NOT NULL DEFAULT 0, \
			    threshold_z  REAL    NOT NULL DEFAULT 0, \
			    has_p2       INTEGER NOT NULL DEFAULT 1, \
			    thresh_down  INTEGER NOT NULL DEFAULT 1, \
			    is_default   INTEGER NOT NULL DEFAULT 0, \
			    UNIQUE(map, steam_id, name))");
    }
}

public void DB_OnCreateTable(Database db, DBResultSet rs, const char[] error, any data)
{
    if (rs == null)
    {
        LogError("DB_CreateTable failed: %s", error);
        return;
    }
    DB_ImportDefaults();
}

void DB_ImportDefaults()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), DEFAULTS_PATH);

    if (!FileExists(path))
    {
        if (IsServerProcessing())
            DB_LoadDefaults();
        return;
    }

    KeyValues kv = new KeyValues("MissedByDefaults");
    if (!kv.ImportFromFile(path))
    {
        delete kv;
        if (IsServerProcessing())
            DB_LoadDefaults();
        return;
    }

    if (kv.GotoFirstSubKey())
    {
        do
        {
            char mapName[PLATFORM_MAX_PATH];
            kv.GetSectionName(mapName, sizeof(mapName));

            char escapedMap[PLATFORM_MAX_PATH * 2 + 1];
            g_hDB.Escape(mapName, escapedMap, sizeof(escapedMap));

            if (kv.GotoFirstSubKey())
            {
                do
                {
                    char zoneName[MAX_NAME_LEN];
                    kv.GetSectionName(zoneName, sizeof(zoneName));

                    char escapedName[MAX_NAME_LEN * 2 + 1];
                    g_hDB.Escape(zoneName, escapedName, sizeof(escapedName));

                    float p0x = kv.GetFloat("point0_x");
                    float p0y = kv.GetFloat("point0_y");
                    float p1x = kv.GetFloat("point1_x");
                    float p1y = kv.GetFloat("point1_y");
                    float p2x = kv.GetFloat("point2_x");
                    float p2y = kv.GetFloat("point2_y");
                    float tz  = kv.GetFloat("threshold_z");
                    int   hp2 = kv.GetNum("has_p2", 1);
                    int   tdn = kv.GetNum("thresh_down", 1);

                    char  query[512];
                    if (g_eDbType == DatabaseType_MySQL)
                    {
                        FormatEx(query, sizeof(query),
                                 "INSERT IGNORE INTO Zones \
							    (map, name, steam_id, point0_x, point0_y, point1_x, point1_y, \
							     point2_x, point2_y, threshold_z, has_p2, thresh_down, is_default) \
							 VALUES ('%s', '%s', '', %f, %f, %f, %f, %f, %f, %f, %d, %d, 1)",
                                 escapedMap, escapedName,
                                 p0x, p0y, p1x, p1y, p2x, p2y, tz, hp2, tdn);
                    }
                    else
                    {
                        FormatEx(query, sizeof(query),
                                 "INSERT OR IGNORE INTO Zones \
							    (map, name, steam_id, point0_x, point0_y, point1_x, point1_y, \
							     point2_x, point2_y, threshold_z, has_p2, thresh_down, is_default) \
							 VALUES ('%s', '%s', '', %f, %f, %f, %f, %f, %f, %f, %d, %d, 1)",
                                 escapedMap, escapedName,
                                 p0x, p0y, p1x, p1y, p2x, p2y, tz, hp2, tdn);
                    }

                    g_hDB.Query(DB_OnImportRow, query);
                }
                while (kv.GotoNextKey());

                kv.GoBack();
            }
        }
        while (kv.GotoNextKey());
    }

    delete kv;

    if (IsServerProcessing())
        DB_LoadDefaults();
}

public void DB_OnImportRow(Database db, DBResultSet rs, const char[] error, any data)
{
    if (rs == null)
        LogError("DB_ImportDefaults row failed: %s", error);
}

void DB_LoadDefaults()
{
    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMap(mapName, sizeof(mapName));

    char escapedMap[PLATFORM_MAX_PATH * 2 + 1];
    g_hDB.Escape(mapName, escapedMap, sizeof(escapedMap));

    char query[512];
    FormatEx(query, sizeof(query),
             "SELECT id, name, point0_x, point0_y, point1_x, point1_y, \
		        point2_x, point2_y, threshold_z, has_p2, thresh_down, is_default \
		 FROM Zones WHERE map = '%s' AND is_default = 1 ORDER BY name ASC",
             escapedMap);

    g_hDB.Query(DB_OnLoadDefaults, query);
}

public void DB_OnLoadDefaults(Database db, DBResultSet rs, const char[] error, any data)
{
    if (rs == null)
    {
        LogError("DB_LoadDefaults failed: %s", error);
        return;
    }

    // Remove all existing defaults (owner == -1) before reloading
    RemoveDefaultZones();

    while (rs.FetchRow() && g_iZoneCount < MAX_ZONES)
    {
        int i        = g_iZoneCount;
        g_iZoneId[i] = rs.FetchInt(0);
        rs.FetchString(1, g_sZoneName[i], MAX_NAME_LEN);
        g_fZoneP0[i][0]           = rs.FetchFloat(2);
        g_fZoneP0[i][1]           = rs.FetchFloat(3);
        g_fZoneP1[i][0]           = rs.FetchFloat(4);
        g_fZoneP1[i][1]           = rs.FetchFloat(5);
        g_fZoneP2[i][0]           = rs.FetchFloat(6);
        g_fZoneP2[i][1]           = rs.FetchFloat(7);
        g_fZoneThreshZ[i]         = rs.FetchFloat(8);
        g_bZoneHasP2[i]           = rs.FetchInt(9) != 0;
        g_bZoneThreshDown[i]      = rs.FetchInt(10) != 0;
        g_bZoneIsDefault[i]       = true;
        g_iZoneOwner[i]           = -1;
        g_sZoneOwnerSteamId[i][0] = '\0';
        g_iZoneCount++;
    }

    // Load zones for all currently connected players
    for (int c = 1; c <= MaxClients; c++)
    {
        if (IsClientInGame(c) && !IsFakeClient(c) && IsClientAuthorized(c))
            DB_LoadPlayerZones(c);
    }
}

void DB_LoadPlayerZones(int client)
{
    char steamId[STEAMID_LEN];
    if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId)))
        return;

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMap(mapName, sizeof(mapName));

    char escapedMap[PLATFORM_MAX_PATH * 2 + 1];
    char escapedSteam[STEAMID_LEN * 2 + 1];
    g_hDB.Escape(mapName, escapedMap, sizeof(escapedMap));
    g_hDB.Escape(steamId, escapedSteam, sizeof(escapedSteam));

    char query[512];
    FormatEx(query, sizeof(query),
             "SELECT id, name, point0_x, point0_y, point1_x, point1_y, \
		        point2_x, point2_y, threshold_z, has_p2, thresh_down, is_default \
		 FROM Zones WHERE map = '%s' AND steam_id = '%s' ORDER BY name ASC",
             escapedMap, escapedSteam);

    g_hDB.Query(DB_OnLoadPlayerZones, query, GetClientUserId(client));
}

public void DB_OnLoadPlayerZones(Database db, DBResultSet rs, const char[] error, any userid)
{
    int client = GetClientOfUserId(view_as<int>(userid));
    if (client == 0)
        return;

    if (rs == null)
    {
        LogError("DB_LoadPlayerZones failed: %s", error);
        return;
    }

    // Remove old entries for this client before re-adding
    RemoveClientZones(client);

    char steamId[STEAMID_LEN];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

    while (rs.FetchRow() && g_iZoneCount < MAX_ZONES)
    {
        int i        = g_iZoneCount;
        g_iZoneId[i] = rs.FetchInt(0);
        rs.FetchString(1, g_sZoneName[i], MAX_NAME_LEN);
        g_fZoneP0[i][0]      = rs.FetchFloat(2);
        g_fZoneP0[i][1]      = rs.FetchFloat(3);
        g_fZoneP1[i][0]      = rs.FetchFloat(4);
        g_fZoneP1[i][1]      = rs.FetchFloat(5);
        g_fZoneP2[i][0]      = rs.FetchFloat(6);
        g_fZoneP2[i][1]      = rs.FetchFloat(7);
        g_fZoneThreshZ[i]    = rs.FetchFloat(8);
        g_bZoneHasP2[i]      = rs.FetchInt(9) != 0;
        g_bZoneThreshDown[i] = rs.FetchInt(10) != 0;
        g_bZoneIsDefault[i]  = rs.FetchInt(11) != 0;
        g_iZoneOwner[i]      = client;
        strcopy(g_sZoneOwnerSteamId[i], STEAMID_LEN, steamId);
        g_iZoneCount++;
    }
}

void DB_SaveZone(int client, const char[] name)
{
    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMap(mapName, sizeof(mapName));

    char steamId[STEAMID_LEN];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

    char escapedMap[PLATFORM_MAX_PATH * 2 + 1];
    char escapedName[MAX_NAME_LEN * 2 + 1];
    char escapedSteam[STEAMID_LEN * 2 + 1];
    g_hDB.Escape(mapName, escapedMap, sizeof(escapedMap));
    g_hDB.Escape(name, escapedName, sizeof(escapedName));
    g_hDB.Escape(steamId, escapedSteam, sizeof(escapedSteam));

    int  hasP2    = g_bWsPosSet[client][2] ? 1 : 0;
    int  threshDn = g_bWsThreshDown[client] ? 1 : 0;
    char query[1024];
    if (g_eDbType == DatabaseType_MySQL)
    {
        FormatEx(query, sizeof(query),
                 "INSERT INTO Zones (map, steam_id, name, point0_x, point0_y, point1_x, point1_y, \
			                    point2_x, point2_y, threshold_z, has_p2, thresh_down) \
			 VALUES ('%s', '%s', '%s', %f, %f, %f, %f, %f, %f, %f, %d, %d) \
			 ON DUPLICATE KEY UPDATE \
			    point0_x=VALUES(point0_x), point0_y=VALUES(point0_y), \
			    point1_x=VALUES(point1_x), point1_y=VALUES(point1_y), \
			    point2_x=VALUES(point2_x), point2_y=VALUES(point2_y), \
			    threshold_z=VALUES(threshold_z), has_p2=VALUES(has_p2), \
			    thresh_down=VALUES(thresh_down)",
                 escapedMap, escapedSteam, escapedName,
                 g_fWsP0[client][0], g_fWsP0[client][1],
                 g_fWsP1[client][0], g_fWsP1[client][1],
                 g_fWsP2[client][0], g_fWsP2[client][1],
                 g_fWsThreshZ[client], hasP2, threshDn);
    }
    else
    {
        FormatEx(query, sizeof(query),
                 "INSERT OR REPLACE INTO Zones \
			    (map, steam_id, name, point0_x, point0_y, point1_x, point1_y, \
			     point2_x, point2_y, threshold_z, has_p2, thresh_down) \
			 VALUES ('%s', '%s', '%s', %f, %f, %f, %f, %f, %f, %f, %d, %d)",
                 escapedMap, escapedSteam, escapedName,
                 g_fWsP0[client][0], g_fWsP0[client][1],
                 g_fWsP1[client][0], g_fWsP1[client][1],
                 g_fWsP2[client][0], g_fWsP2[client][1],
                 g_fWsThreshZ[client], hasP2, threshDn);
    }

    g_hDB.Query(DB_OnSaveZone, query, GetClientUserId(client));
}

public void DB_OnSaveZone(Database db, DBResultSet rs, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);

    if (rs == null)
    {
        LogError("DB_SaveZone failed: %s", error);
        if (client != 0)
            GOKZ_PrintToChat(client, true, "{darkred}Save failed. Check server log.");
        return;
    }

    if (client != 0)
    {
        GOKZ_PrintToChat(client, true, "{default}Zone saved.");
        delete g_hWsCrossTimer[client];
        for (int i = 0; i < 4; i++)
            g_bWsPosSet[client][i] = false;
        DB_LoadPlayerZones(client);
    }
}

void DB_DeleteZone(int client, int zoneIdx)
{
    if (zoneIdx < 0 || zoneIdx >= g_iZoneCount)
        return;

    char query[128];
    FormatEx(query, sizeof(query), "DELETE FROM Zones WHERE id = %d", g_iZoneId[zoneIdx]);

    g_hDB.Query(DB_OnDeleteZone, query, GetClientUserId(client));
}

public void DB_OnDeleteZone(Database db, DBResultSet rs, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);

    if (rs == null)
    {
        LogError("DB_DeleteZone failed: %s", error);
        if (client != 0)
            GOKZ_PrintToChat(client, true, "{darkred}Delete failed. Check server log.");
        return;
    }

    if (client != 0)
    {
        GOKZ_PrintToChat(client, true, "{default}Zone deleted.");
        DB_LoadPlayerZones(client);
    }
}

// ===== Commands =====
public Action CmdMissedBy(int client, int args)
{
    if (client == 0)
        return Plugin_Handled;
    OpenMainMenu(client);
    return Plugin_Handled;
}

public Action CmdSayListener(int client, const char[] command, int argc)
{
    if (!g_bAwaitingName[client])
        return Plugin_Continue;

    char text[MAX_NAME_LEN];
    GetCmdArgString(text, sizeof(text));

    if (text[0] == '"')
    {
        int len = strlen(text);
        if (len >= 2 && text[len - 1] == '"')
            text[len - 1] = '\0';
        strcopy(text, sizeof(text), text[1]);
    }

    if (text[0] == '\0')
    {
        GOKZ_PrintToChat(client, true, "{darkred}Name cannot be empty. Type a name:");
        return Plugin_Stop;
    }

    g_bAwaitingName[client] = false;
    DB_SaveZone(client, text);

    return Plugin_Stop;
}

// ===== Menus =====
void OpenMainMenu(int client)
{
    Menu menu = new Menu(MenuHandler_Main);
    menu.SetTitle("Missed By");

    char toggleLabel[48];
    FormatEx(toggleLabel, sizeof(toggleLabel), "Helper: %s", g_bEnable[client] ? "ON" : "OFF");
    menu.AddItem("toggle", toggleLabel);

    menu.AddItem("zones", "Zones");

    menu.AddItem("", "---", ITEMDRAW_DISABLED);
    menu.AddItem("setup", g_bWsInProgress[client] ? "Continue Zone Setup..." : "New Zone Setup");

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Main(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[8];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "toggle"))
        {
            g_bEnable[client] = !g_bEnable[client];
            SetClientCookie(client, g_hCookieEnable, g_bEnable[client] ? "1" : "0");
            GOKZ_PrintToChat(client, true, "{default}Jump Miss Helper: %s",
                             g_bEnable[client] ? "{green}ON" : "{darkred}OFF");
            OpenMainMenu(client);
        }
        else if (StrEqual(info, "zones"))
        {
            OpenZonesMenu(client);
        }
        else if (StrEqual(info, "setup"))
        {
            OpenSetupMenu(client);
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void OpenZonesMenu(int client)
{
    Menu menu = new Menu(MenuHandler_Zones);
    menu.SetTitle("Zones");
    menu.ExitBackButton = true;

    bool anyZone        = false;
    bool anyCustom      = false;
    for (int i = 0; i < g_iZoneCount; i++)
    {
        if (g_iZoneOwner[i] != -1 && g_iZoneOwner[i] != client)
            continue;
        anyZone = true;
        if (!g_bZoneIsDefault[i])
            anyCustom = true;
        char label[MAX_NAME_LEN + 16];
        char info[8];
        FormatEx(info, sizeof(info), "z%d", i);
        FormatEx(label, sizeof(label), "%s%s  [%s]",
                 g_bZoneIsDefault[i] ? "[D] " : "",
                 g_sZoneName[i],
                 IsZoneDisabled(client, i) ? "OFF" : "ON");
        menu.AddItem(info, label);
    }
    if (!anyZone)
        menu.AddItem("", "No zones for this map", ITEMDRAW_DISABLED);

    if (anyCustom)
    {
        menu.AddItem("", "---", ITEMDRAW_DISABLED);
        menu.AddItem("delete", "Delete a zone...");
    }

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Zones(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[8];
        menu.GetItem(param2, info, sizeof(info));

        if (info[0] == 'z')
        {
            int idx = StringToInt(info[1]);
            if (idx >= 0 && idx < g_iZoneCount)
            {
                // Every zone is independently toggleable; on by default.
                bool nowOff = !IsZoneDisabled(client, idx);
                SetZoneDisabled(client, idx, nowOff);
                GOKZ_PrintToChat(client, true, "{default}%s{purple}%s{default}: %s",
                                 g_bZoneIsDefault[idx] ? "Default zone " : "Zone ",
                                 g_sZoneName[idx], nowOff ? "{darkred}OFF" : "{green}ON");
                if (!nowOff)
                    FlashZone(client, idx);
            }
            OpenZonesMenu(client);
        }
        else if (StrEqual(info, "delete"))
        {
            OpenDeleteListMenu(client);
            return 0;
        }
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
            OpenMainMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void OpenDeleteListMenu(int client)
{
    Menu menu = new Menu(MenuHandler_DeleteList);
    menu.SetTitle("Delete which zone?");
    menu.ExitBackButton = true;

    bool any            = false;
    for (int i = 0; i < g_iZoneCount; i++)
    {
        if (g_bZoneIsDefault[i] || g_iZoneOwner[i] != client)
            continue;
        any = true;
        char info[8];
        FormatEx(info, sizeof(info), "d%d", i);
        menu.AddItem(info, g_sZoneName[i]);
    }
    if (!any)
        menu.AddItem("", "No custom zones to delete", ITEMDRAW_DISABLED);

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_DeleteList(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[8];
        menu.GetItem(param2, info, sizeof(info));
        if (info[0] == 'd')
        {
            int idx = StringToInt(info[1]);
            if (idx >= 0 && idx < g_iZoneCount && !g_bZoneIsDefault[idx] && g_iZoneOwner[idx] == client)
            {
                OpenDeleteConfirmMenu(client, idx);
                return 0;
            }
        }
        OpenZonesMenu(client);
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
            OpenZonesMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void OpenDeleteConfirmMenu(int client, int zoneIdx)
{
    Menu menu = new Menu(MenuHandler_DeleteConfirm);
    char title[MAX_NAME_LEN + 24];
    FormatEx(title, sizeof(title), "Delete \"%s\"?", g_sZoneName[zoneIdx]);
    menu.SetTitle(title);
    menu.ExitBackButton = true;

    char info[8];
    FormatEx(info, sizeof(info), "y%d", zoneIdx);
    menu.AddItem(info, "Yes, delete");
    menu.AddItem("no", "No, cancel");

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_DeleteConfirm(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[8];
        menu.GetItem(param2, info, sizeof(info));

        if (info[0] == 'y')
        {
            int idx = StringToInt(info[1]);
            if (idx >= 0 && idx < g_iZoneCount && !g_bZoneIsDefault[idx] && g_iZoneOwner[idx] == client)
                DB_DeleteZone(client, idx);
        }
        else
        {
            OpenZonesMenu(client);
        }
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
            OpenZonesMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void OpenSetupMenu(int client)
{
    Menu menu = new Menu(MenuHandler_Setup);
    menu.SetTitle("Zone Setup\n \nAim at surface. P0/P1/P2 = XY. P2 optional.");

    // Mode toggle is always first
    char modeLabel[48];
    char modeName[16];
    if (g_iPlaceMode[client] == PLACE_MODE_SNAP_GRID) strcopy(modeName, sizeof(modeName), "Grid");
    else if (g_iPlaceMode[client] == PLACE_MODE_SNAP) strcopy(modeName, sizeof(modeName), "Snap");
    else if (g_iPlaceMode[client] == PLACE_MODE_PRECISE) strcopy(modeName, sizeof(modeName), "Precise");
    else strcopy(modeName, sizeof(modeName), "Feet");
    FormatEx(modeLabel, sizeof(modeLabel), "Mode: %s", modeName);
    menu.AddItem("mode", modeLabel);

    menu.AddItem("", "---", ITEMDRAW_DISABLED);

    char label[64];

    FormatEx(label, sizeof(label), "Set Point 0  (%.1f, %.1f)",
             g_fWsP0[client][0], g_fWsP0[client][1]);
    menu.AddItem("p0", label);

    FormatEx(label, sizeof(label), "Set Point 1 / apex  (%.1f, %.1f)",
             g_fWsP1[client][0], g_fWsP1[client][1]);
    menu.AddItem("p1", label);

    if (g_bWsPosSet[client][2])
        FormatEx(label, sizeof(label), "Set Point 2 (optional)  (%.1f, %.1f)",
                 g_fWsP2[client][0], g_fWsP2[client][1]);
    else
        strcopy(label, sizeof(label), "Set Point 2 (optional)  (not set)");
    menu.AddItem("p2", label);

    if (g_bWsPosSet[client][2])
        menu.AddItem("p2clear", "  Clear Point 2");

    FormatEx(label, sizeof(label), "Set Crossing Z  (%.5f)", g_fWsThreshZ[client]);
    menu.AddItem("threshz", label);

    FormatEx(label, sizeof(label), "Direction: %s",
             g_bWsThreshDown[client] ? "Downward (default)" : "Upward");
    menu.AddItem("threshdir", label);

    menu.AddItem("", "---", ITEMDRAW_DISABLED);
    menu.AddItem("saveas", "Save as...");
    menu.AddItem("back", "Back");

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Setup(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "back"))
        {
            OpenMainMenu(client);
        }
        else if (StrEqual(info, "mode"))
        {
            if (g_iPlaceMode[client] == PLACE_MODE_SNAP_GRID) g_iPlaceMode[client] = PLACE_MODE_SNAP;
            else if (g_iPlaceMode[client] == PLACE_MODE_SNAP) g_iPlaceMode[client] = PLACE_MODE_PRECISE;
            else if (g_iPlaceMode[client] == PLACE_MODE_PRECISE) g_iPlaceMode[client] = PLACE_MODE_FEET;
            else g_iPlaceMode[client] = PLACE_MODE_SNAP_GRID;
            OpenSetupMenu(client);
        }
        else if (StrEqual(info, "saveas"))
        {
            g_bAwaitingName[client] = true;
            GOKZ_PrintToChat(client, true, "{default}Type zone name in chat:");
        }
        else if (StrEqual(info, "p2clear"))
        {
            g_bWsPosSet[client][2]   = false;
            g_fWsP2[client][0]       = 0.0;
            g_fWsP2[client][1]       = 0.0;
            g_fWsPos3D[client][2][0] = 0.0;
            g_fWsPos3D[client][2][1] = 0.0;
            g_fWsPos3D[client][2][2] = 0.0;
            WsCrossStart(client);
            GOKZ_PrintToChat(client, true, "{default}P2 cleared.");
            OpenSetupMenu(client);
        }
        else if (StrEqual(info, "threshdir"))
        {
            g_bWsThreshDown[client] = !g_bWsThreshDown[client];
            GOKZ_PrintToChat(client, true, "{default}Threshold direction: {purple}%s",
                             g_bWsThreshDown[client] ? "Downward" : "Upward");
            OpenSetupMenu(client);
        }
        else
        {
            // p0, p1, p2, threshz
            PlaceWorkspacePoint(client, info);
        }
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
            OpenMainMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

// ===== Crosshair placement =====

// Trace from client's crosshair into the world.
// Returns true and fills hitPos/hitNorm on hit.
bool GetCrosshairHit(int client, float hitPos[3], float hitNorm[3])
{
    float eyePos[3], eyeAng[3], aimDir[3];
    GetClientEyePosition(client, eyePos);
    GetClientEyeAngles(client, eyeAng);
    GetAngleVectors(eyeAng, aimDir, NULL_VECTOR, NULL_VECTOR);

    float endPos[3];
    endPos[0]    = eyePos[0] + aimDir[0] * 8192.0;
    endPos[1]    = eyePos[1] + aimDir[1] * 8192.0;
    endPos[2]    = eyePos[2] + aimDir[2] * 8192.0;

    Handle trace = TR_TraceRayFilterEx(eyePos, endPos, MASK_SOLID, RayType_EndPoint,
                                       TraceEntityFilterPlayers);
    bool   hit   = TR_DidHit(trace);
    if (hit)
    {
        TR_GetEndPosition(hitPos, trace);
        TR_GetPlaneNormal(trace, hitNorm);
    }
    delete trace;
    return hit;
}

// Probe whether testPos lies on a surface whose normal matches refNorm.
// Shoots a short ray through the surface from the +normal side to the -normal side.
bool ProbeOnSurface(const float testPos[3], const float normal[3], const float refNorm[3])
{
    float start[3], end[3];
    start[0]   = testPos[0] + normal[0] * EDGE_PROBE_DIST;
    start[1]   = testPos[1] + normal[1] * EDGE_PROBE_DIST;
    start[2]   = testPos[2] + normal[2] * EDGE_PROBE_DIST;
    end[0]     = testPos[0] - normal[0] * EDGE_PROBE_DIST;
    end[1]     = testPos[1] - normal[1] * EDGE_PROBE_DIST;
    end[2]     = testPos[2] - normal[2] * EDGE_PROBE_DIST;

    Handle h   = TR_TraceRayFilterEx(start, end, MASK_SOLID, RayType_EndPoint,
                                     TraceEntityFilterPlayers);
    bool   hit = TR_DidHit(h);
    if (hit)
    {
        float norm[3];
        TR_GetPlaneNormal(h, norm);
        delete h;
        return GetVectorDotProduct(norm, refNorm) >= NORMAL_DOT_MIN;
    }
    delete h;
    return false;
}

// Build two orthogonal tangent vectors in the plane whose normal is `normal`.
void GetSurfaceTangents(const float normal[3], float tA[3], float tB[3])
{
    float ref[3];
    if (FloatAbs(normal[2]) < 0.99)
    {
        ref[0] = 0.0;
        ref[1] = 0.0;
        ref[2] = 1.0;
    }
    else
    {
        ref[0] = 1.0;
        ref[1] = 0.0;
        ref[2] = 0.0;
    }
    GetVectorCrossProduct(ref, normal, tA);
    NormalizeVector(tA, tA);
    GetVectorCrossProduct(normal, tA, tB);
    NormalizeVector(tB, tB);
}

// Search radially in SNAP_DIRS directions along the surface from hitPos.
// Returns true with result = the nearest edge found.
bool FindNearestEdge(const float hitPos[3], const float normal[3], float result[3])
{
    float tA[3], tB[3];
    GetSurfaceTangents(normal, tA, tB);

    float bestDist = EDGE_SEARCH_DIST + 1.0;
    bool  found    = false;

    for (int d = 0; d < SNAP_DIRS; d++)
    {
        float angle = float(d) * (6.283185 / float(SNAP_DIRS));
        float stepDir[3];
        stepDir[0] = Cosine(angle) * tA[0] + Sine(angle) * tB[0];
        stepDir[1] = Cosine(angle) * tA[1] + Sine(angle) * tB[1];
        stepDir[2] = Cosine(angle) * tA[2] + Sine(angle) * tB[2];

        float farPos[3];
        farPos[0] = hitPos[0] + stepDir[0] * EDGE_SEARCH_DIST;
        farPos[1] = hitPos[1] + stepDir[1] * EDGE_SEARCH_DIST;
        farPos[2] = hitPos[2] + stepDir[2] * EDGE_SEARCH_DIST;

        if (ProbeOnSurface(farPos, normal, normal))
            continue;

        float lo = 0.0, hi = EDGE_SEARCH_DIST;
        for (int iter = 0; iter < EDGE_ITERATIONS; iter++)
        {
            float mid = (lo + hi) * 0.5;
            float testPos[3];
            testPos[0] = hitPos[0] + stepDir[0] * mid;
            testPos[1] = hitPos[1] + stepDir[1] * mid;
            testPos[2] = hitPos[2] + stepDir[2] * mid;
            if (ProbeOnSurface(testPos, normal, normal))
                lo = mid;
            else
                hi = mid;
        }

        if (lo < bestDist)
        {
            bestDist  = lo;
            result[0] = hitPos[0] + stepDir[0] * lo;
            result[1] = hitPos[1] + stepDir[1] * lo;
            result[2] = hitPos[2] + stepDir[2] * lo;
            found     = true;
        }
    }

    return found;
}

// If a near-vertical wall face is within SNAP_WALL_DIST of pos, project pos onto it.
void SnapToNearbyWall(float pos[3])
{
    float bestDist = SNAP_WALL_DIST;
    float bestNorm[3], bestHit[3];
    bool  found = false;

    for (int d = 0; d < 8; d++)
    {
        float angle = float(d) * (6.283185 / 8.0);
        float end[3];
        end[0]   = pos[0] + Cosine(angle) * SNAP_WALL_DIST;
        end[1]   = pos[1] + Sine(angle) * SNAP_WALL_DIST;
        end[2]   = pos[2];

        Handle h = TR_TraceRayFilterEx(pos, end, MASK_SOLID, RayType_EndPoint,
                                       TraceEntityFilterPlayers);
        if (!TR_DidHit(h))
        {
            delete h;
            continue;
        }

        float norm[3];
        TR_GetPlaneNormal(h, norm);
        if (FloatAbs(norm[2]) > 0.5)
        {
            delete h;
            continue;
        }    // floor/ceiling, not a wall

        float hitPt[3];
        TR_GetEndPosition(hitPt, h);
        delete h;

        float dist = GetVectorDistance(pos, hitPt);
        if (dist < bestDist)
        {
            bestDist    = dist;
            bestNorm[0] = norm[0];
            bestNorm[1] = norm[1];
            bestNorm[2] = norm[2];
            bestHit[0]  = hitPt[0];
            bestHit[1]  = hitPt[1];
            bestHit[2]  = hitPt[2];
            found       = true;
        }
    }

    if (found)
    {
        // Project pos onto the wall plane: remove component along wall normal.
        float d = GetVectorDotProduct(pos, bestNorm) - GetVectorDotProduct(bestHit, bestNorm);
        pos[0] -= d * bestNorm[0];
        pos[1] -= d * bestNorm[1];
        pos[2] -= d * bestNorm[2];
    }
}

// Resolve the final placement position for a workspace point, then apply it.
void PlaceWorkspacePoint(int client, const char[] point)
{
    float placePos[3];

    if (g_iPlaceMode[client] == PLACE_MODE_FEET)
    {
        GetClientAbsOrigin(client, placePos);
    }
    else
    {
        float hitPos[3], hitNorm[3];
        if (!GetCrosshairHit(client, hitPos, hitNorm))
        {
            GOKZ_PrintToChat(client, true, "{darkred}No surface in crosshair.");
            OpenSetupMenu(client);
            return;
        }

        placePos[0] = hitPos[0];
        placePos[1] = hitPos[1];
        placePos[2] = hitPos[2];

        if (g_iPlaceMode[client] == PLACE_MODE_SNAP_GRID)
        {
            placePos[0] = RoundToNearest(placePos[0]) * 1.0;
            placePos[1] = RoundToNearest(placePos[1]) * 1.0;
            placePos[2] = RoundToNearest(placePos[2]) * 1.0;
        }
        else if (g_iPlaceMode[client] == PLACE_MODE_SNAP)
        {
            float edgePos[3];
            if (FindNearestEdge(hitPos, hitNorm, edgePos))
            {
                placePos[0] = edgePos[0];
                placePos[1] = edgePos[1];
                placePos[2] = edgePos[2];
            }
            else
            {
                GOKZ_PrintToChat(client, true,
                                 "{darkred}No edge found within search range. Using raw crosshair point.");
            }
            SnapToNearbyWall(placePos);
        }
    }

    // Compute the floor Z from this placement (used to auto-update threshold).
    // placePos[2] is either a surface hit or abs origin - both sit GROUND_EPSILON above the floor.
    float autoThreshZ = placePos[2] - GROUND_EPSILON;

    if (StrEqual(point, "p0"))
    {
        g_fWsP0[client][0]       = placePos[0];
        g_fWsP0[client][1]       = placePos[1];
        g_fWsPos3D[client][0][0] = placePos[0];
        g_fWsPos3D[client][0][1] = placePos[1];
        g_fWsPos3D[client][0][2] = placePos[2];
        g_bWsPosSet[client][0]   = true;
        g_bWsInProgress[client]  = true;
        GOKZ_PrintToChat(client, true, "{default}P0: [{purple}%.3f, %.3f{default}]", placePos[0], placePos[1]);
        g_fWsThreshZ[client]     = autoThreshZ;
        g_fWsPos3D[client][3][0] = placePos[0];
        g_fWsPos3D[client][3][1] = placePos[1];
        g_fWsPos3D[client][3][2] = autoThreshZ;
        g_bWsPosSet[client][3]   = true;
    }
    else if (StrEqual(point, "p1"))
    {
        g_fWsP1[client][0]       = placePos[0];
        g_fWsP1[client][1]       = placePos[1];
        g_fWsPos3D[client][1][0] = placePos[0];
        g_fWsPos3D[client][1][1] = placePos[1];
        g_fWsPos3D[client][1][2] = placePos[2];
        g_bWsPosSet[client][1]   = true;
        g_bWsInProgress[client]  = true;
        GOKZ_PrintToChat(client, true, "{default}P1: [{purple}%.3f, %.3f{default}]", placePos[0], placePos[1]);
        g_fWsThreshZ[client]     = autoThreshZ;
        g_fWsPos3D[client][3][0] = placePos[0];
        g_fWsPos3D[client][3][1] = placePos[1];
        g_fWsPos3D[client][3][2] = autoThreshZ;
        g_bWsPosSet[client][3]   = true;
    }
    else if (StrEqual(point, "p2"))
    {
        g_fWsP2[client][0]       = placePos[0];
        g_fWsP2[client][1]       = placePos[1];
        g_fWsPos3D[client][2][0] = placePos[0];
        g_fWsPos3D[client][2][1] = placePos[1];
        g_fWsPos3D[client][2][2] = placePos[2];
        g_bWsPosSet[client][2]   = true;
        g_bWsInProgress[client]  = true;
        GOKZ_PrintToChat(client, true, "{default}P2: [{purple}%.3f, %.3f{default}]", placePos[0], placePos[1]);
        g_fWsThreshZ[client]     = autoThreshZ;
        g_fWsPos3D[client][3][0] = placePos[0];
        g_fWsPos3D[client][3][1] = placePos[1];
        g_fWsPos3D[client][3][2] = autoThreshZ;
        g_bWsPosSet[client][3]   = true;
    }
    else if (StrEqual(point, "threshz"))
    {
        // Manual override: subtract epsilon regardless of placement mode.
        g_fWsThreshZ[client]     = autoThreshZ;
        g_fWsPos3D[client][3][0] = placePos[0];
        g_fWsPos3D[client][3][1] = placePos[1];
        g_fWsPos3D[client][3][2] = autoThreshZ;
        g_bWsPosSet[client][3]   = true;
        g_bWsInProgress[client]  = true;
        GOKZ_PrintToChat(client, true, "{default}Crossing Z override: {purple}%.5f", autoThreshZ);
    }
    WsCrossStart(client);
    OpenSetupMenu(client);
}

// ===== Detection =====
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3],
                      float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount,
                      int &seed, int mouse[2])
{
    if (IsPlayerAlive(client))
        GetClientAbsOrigin(client, g_fStartOrigin[client]);
    return Plugin_Continue;
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3],
                        const float angles[3], int weapon, int subtype, int cmdnum, int tickcount,
                        int seed, const int mouse[2])
{
    if (!IsPlayerAlive(client))
        return;

    GetClientAbsOrigin(client, g_fEndOrigin[client]);
    g_bOldDuck[client] = Movement_GetDucking(client);

    float startZ       = g_fStartOrigin[client][2];
    float endZ         = g_fEndOrigin[client][2];

    // Audience = the runner plus anyone spectating them, who has the helper on.
    // Each viewer is judged against the zones active for THAT viewer, so default
    // zones (active for everyone unless toggled off) and a viewer's own selected
    // custom zone all fire from a single pass.
    for (int viewer = 1; viewer <= MaxClients; viewer++)
    {
        if (!IsClientInGame(viewer) || !g_bEnable[viewer])
            continue;
        if (viewer != client && GetObserverTarget(viewer) != client)
            continue;

        char duckStr[16];
        strcopy(duckStr, sizeof(duckStr), Movement_GetDucking(client) ? "ducked" : "standing");

        for (int z = 0; z < g_iZoneCount; z++)
        {
            if (!IsZoneActiveFor(viewer, z))
                continue;

            float distance, originStart[3], originEnd[3];
            if (!ComputeZoneMiss(client, z, startZ, endZ, distance, originStart, originEnd))
                continue;

            if (viewer == client)
                GOKZ_PrintToChat(viewer, true,
                                 "{purple}You{default} were {darkred}%.2f {default}away from {purple}%s{default}! (%s)",
                                 distance, g_sZoneName[z], duckStr);
            else
                GOKZ_PrintToChat(viewer, true,
                                 "{purple}%N{default} was {darkred}%.2f {default}away from {purple}%s{default}! (%s)",
                                 client, distance, g_sZoneName[z], duckStr);
            DrawMissBeam(viewer, originStart, originEnd, distance);
        }
    }
}

// Whether zone z should fire for viewer.
// Every zone visible to the viewer (defaults, plus their own custom zones) is on by default;
// the viewer can independently toggle any of them off.
bool IsZoneActiveFor(int viewer, int z)
{
    if (!g_bZoneIsDefault[z] && g_iZoneOwner[z] != viewer)
        return false;
    return !IsZoneDisabled(viewer, z);
}

bool IsZoneDisabled(int client, int z)
{
    if (g_hDisabledZones[client] == null)
        return false;
    return g_hDisabledZones[client].FindValue(g_iZoneId[z]) != -1;
}

void SetZoneDisabled(int client, int z, bool disabled)
{
    if (g_hDisabledZones[client] == null)
        g_hDisabledZones[client] = new ArrayList();

    int idx = g_hDisabledZones[client].FindValue(g_iZoneId[z]);
    if (disabled)
    {
        if (idx == -1)
            g_hDisabledZones[client].Push(g_iZoneId[z]);
    }
    else if (idx != -1)
    {
        g_hDisabledZones[client].Erase(idx);
    }
}

// Test runner's last-tick trajectory against zone z. On a hit (threshold crossed
// and landing within 100u) fills distance + the beam endpoints and returns true.
bool ComputeZoneMiss(int client, int z, float startZ, float endZ,
                     float &distance, float originStart[3], float originEnd[3])
{
    float thresh = g_fZoneThreshZ[z];
    if (thresh == 0.0)
        return false;

    if (g_bZoneThreshDown[z])
    {
        if (endZ > thresh || startZ <= thresh)
            return false;
    }
    else
    {
        if (endZ < thresh || startZ >= thresh)
            return false;
    }

    float t;
    if (FloatAbs(startZ - endZ) < 0.001)
        t = 1.0;
    else
        t = (startZ - thresh) / (startZ - endZ);

    // Two opposite hull corners at the crossing plane. 
    // For each corner take the nearest point on the zone edge,
    // the smallest is the miss, and its corner + edge point become the beam endpoints
    // so the drawn line is the actual miss vector (length = distance, points at the edge).
    float cornerA[2], cornerB[2];
    cornerA[0]  = g_fStartOrigin[client][0] + t * (g_fEndOrigin[client][0] - g_fStartOrigin[client][0]) - 16.0;
    cornerA[1]  = g_fStartOrigin[client][1] + t * (g_fEndOrigin[client][1] - g_fStartOrigin[client][1]) + 16.0;
    cornerB[0]  = cornerA[0] + 32.0;
    cornerB[1]  = cornerA[1];

    float bestD = 999999.0;
    float bestCorner[2], bestTarget[2], cp[2];

    float dd = ClosestPointOnSegment2D(cornerA, g_fZoneP0[z], g_fZoneP1[z], cp);
    if (dd < bestD)
    {
        bestD      = dd;
        bestCorner = cornerA;
        bestTarget = cp;
    }
    dd = ClosestPointOnSegment2D(cornerB, g_fZoneP0[z], g_fZoneP1[z], cp);
    if (dd < bestD)
    {
        bestD      = dd;
        bestCorner = cornerB;
        bestTarget = cp;
    }
    if (g_bZoneHasP2[z])
    {
        dd = ClosestPointOnSegment2D(cornerA, g_fZoneP2[z], g_fZoneP1[z], cp);
        if (dd < bestD)
        {
            bestD      = dd;
            bestCorner = cornerA;
            bestTarget = cp;
        }
        dd = ClosestPointOnSegment2D(cornerB, g_fZoneP2[z], g_fZoneP1[z], cp);
        if (dd < bestD)
        {
            bestD      = dd;
            bestCorner = cornerB;
            bestTarget = cp;
        }
    }

    if (bestD > 150.0)
        return false;

    distance       = bestD;
    originStart[0] = bestCorner[0];
    originStart[1] = bestCorner[1];
    originStart[2] = g_fZoneThreshZ[z];
    originEnd[0]   = bestTarget[0];
    originEnd[1]   = bestTarget[1];
    originEnd[2]   = g_fZoneThreshZ[z];
    return true;
}

// ===== Helpers =====

// Closest point on segment a->b to point p (2D). Fills `out`, returns the distance.
float ClosestPointOnSegment2D(float p[2], float a[2], float b[2], float out[2])
{
    float dx     = b[0] - a[0];
    float dy     = b[1] - a[1];
    float len_sq = dx * dx + dy * dy;
    float param  = -1.0;

    if (len_sq != 0.0)
        param = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len_sq;

    if (param < 0.0)
    {
        out[0] = a[0];
        out[1] = a[1];
    }
    else if (param > 1.0)
    {
        out[0] = b[0];
        out[1] = b[1];
    }
    else
    {
        out[0] = a[0] + param * dx;
        out[1] = a[1] + param * dy;
    }

    float rx = p[0] - out[0];
    float ry = p[1] - out[1];
    return SquareRoot(rx * rx + ry * ry);
}

// Returns minimum distance from point p to line segment a->b in 2D.
float GetDistance2D(float p[2], float a[2], float b[2])
{
    float out[2];
    return ClosestPointOnSegment2D(p, a, b, out);
}

void MeasureBeam(int client, float start[3], float end[3], float life, float width,
                 int r, int g, int b)
{
    TE_Start("BeamPoints");
    TE_WriteNum("m_nModelIndex", g_iBeamModel);
    TE_WriteNum("m_nHaloIndex", 0);
    TE_WriteNum("m_nStartFrame", 0);
    TE_WriteNum("m_nFrameRate", 0);
    TE_WriteFloat("m_fLife", life);
    TE_WriteFloat("m_fWidth", width);
    TE_WriteFloat("m_fEndWidth", width);
    TE_WriteNum("m_nFadeLength", 0);
    TE_WriteFloat("m_fAmplitude", 0.0);
    TE_WriteNum("m_nSpeed", 0);
    TE_WriteNum("r", r);
    TE_WriteNum("g", g);
    TE_WriteNum("b", b);
    TE_WriteNum("a", 255);
    TE_WriteNum("m_nFlags", 0);
    TE_WriteVector("m_vecStartPoint", start);
    TE_WriteVector("m_vecEndPoint", end);

    int clients[1];
    clients[0] = client;
    TE_Send(clients, 1, 0.0);
}

// A line from where the player crossed the plane to the nearest point on the zone edge they fell short of.
// Length = miss distance, direction = which way they were off.
// Colour ramps green (just barely) -> red (far off),
// and vertical pillars at each end keep it readable from any angle, including top-down.
void DrawMissBeam(int client, float land[3], float target[3], float distance)
{
    float frac = distance / 100.0;
    if (frac > 1.0)
        frac = 1.0;
    int   r    = RoundToNearest(40.0 + 215.0 * frac);
    int   g    = RoundToNearest(255.0 - 215.0 * frac);
    int   b    = 40;

    float life = 5.0;

    // Horizontal miss vector along the crossing plane.
    MeasureBeam(client, land, target, life, 0.45, r, g, b);

    // Pillar at the landing point (miss color) and at the edge you needed (green).
    float landTop[3], targetTop[3];
    landTop = land;
    landTop[2] += 28.0;
    targetTop = target;
    targetTop[2] += 28.0;
    MeasureBeam(client, land, landTop, life, 0.35, r, g, b);
    MeasureBeam(client, target, targetTop, life, 0.35, 0, 255, 0);
}

// ===== Zone flash (on selection) =====

void FlashZone(int client, int zoneIdx)
{
    float drawZ = g_fZoneThreshZ[zoneIdx];
    float p0[3], p1[3], p2[3];
    p0[0]      = g_fZoneP0[zoneIdx][0];
    p0[1]      = g_fZoneP0[zoneIdx][1];
    p0[2]      = drawZ;
    p1[0]      = g_fZoneP1[zoneIdx][0];
    p1[1]      = g_fZoneP1[zoneIdx][1];
    p1[2]      = drawZ;
    p2[0]      = g_fZoneP2[zoneIdx][0];
    p2[1]      = g_fZoneP2[zoneIdx][1];
    p2[2]      = drawZ;

    float life = 5.0;
    WsCrossBeams(client, p0, life, 0, 255, 0);      // green
    WsCrossBeams(client, p1, life, 255, 255, 0);    // yellow
    MeasureBeam(client, p0, p1, life, 0.15, 180, 180, 180);
    if (g_bZoneHasP2[zoneIdx])
    {
        WsCrossBeams(client, p2, life, 255, 0, 0);    // red
        MeasureBeam(client, p2, p1, life, 0.15, 180, 180, 180);
    }
}

// ===== Workspace cross markers =====

void WsCrossStart(int client)
{
    if (g_hWsCrossTimer[client] != null)
        return;
    g_hWsCrossTimer[client] = CreateTimer(1.0, Timer_WsCross, GetClientUserId(client), TIMER_REPEAT);
    WsCrossDraw(client);
}

public Action Timer_WsCross(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0)
        return Plugin_Stop;
    WsCrossDraw(client);
    return Plugin_Continue;
}

void WsCrossDraw(int client)
{
    // p0=green, p1=yellow, p2=red, threshz=cyan
    static const int cr[4] = { 0, 255, 255, 0 };
    static const int cg[4] = { 255, 255, 0, 255 };
    static const int cb[4] = { 0, 0, 0, 255 };

    for (int i = 0; i < 4; i++)
    {
        if (!g_bWsPosSet[client][i])
            continue;
        float pos[3];
        pos[0] = g_fWsPos3D[client][i][0];
        pos[1] = g_fWsPos3D[client][i][1];
        pos[2] = g_fWsPos3D[client][i][2];
        WsCrossBeams(client, pos, WS_CROSS_LIFE, cr[i], cg[i], cb[i]);
    }

    // Draw zone segment lines: p0->p1 and p2->p1 (grey, at midpoint Z of each pair)
    if (g_bWsPosSet[client][0] && g_bWsPosSet[client][1])
    {
        float a[3], b[3];
        a[0] = g_fWsPos3D[client][0][0];
        a[1] = g_fWsPos3D[client][0][1];
        a[2] = (g_fWsPos3D[client][0][2] + g_fWsPos3D[client][1][2]) * 0.5;
        b[0] = g_fWsPos3D[client][1][0];
        b[1] = g_fWsPos3D[client][1][1];
        b[2] = a[2];
        MeasureBeam(client, a, b, WS_CROSS_LIFE, 0.15, 180, 180, 180);
    }
    if (g_bWsPosSet[client][2] && g_bWsPosSet[client][1])
    {
        float a[3], b[3];
        a[0] = g_fWsPos3D[client][2][0];
        a[1] = g_fWsPos3D[client][2][1];
        a[2] = (g_fWsPos3D[client][2][2] + g_fWsPos3D[client][1][2]) * 0.5;
        b[0] = g_fWsPos3D[client][1][0];
        b[1] = g_fWsPos3D[client][1][1];
        b[2] = a[2];
        MeasureBeam(client, a, b, WS_CROSS_LIFE, 0.15, 180, 180, 180);
    }
}

void WsCrossBeams(int client, float pos[3], float life, int r, int g, int b)
{
    float a0[3], a1[3], a2[3], a3[3];
    a0[0] = pos[0] + WS_CROSS_SIZE;
    a0[1] = pos[1] + WS_CROSS_SIZE;
    a0[2] = pos[2];
    a1[0] = pos[0] - WS_CROSS_SIZE;
    a1[1] = pos[1] - WS_CROSS_SIZE;
    a1[2] = pos[2];
    a2[0] = pos[0] + WS_CROSS_SIZE;
    a2[1] = pos[1] - WS_CROSS_SIZE;
    a2[2] = pos[2];
    a3[0] = pos[0] - WS_CROSS_SIZE;
    a3[1] = pos[1] + WS_CROSS_SIZE;
    a3[2] = pos[2];
    MeasureBeam(client, a0, a1, WS_CROSS_LIFE, 0.2, r, g, b);
    MeasureBeam(client, a2, a3, WS_CROSS_LIFE, 0.2, r, g, b);
}

// ===== Per-player zone management =====

// Disabled state is tracked per client by zone DB id, so slot reindexing here
// needs no remap - the id travels with the slot via CopyZoneSlot.
void RemoveDefaultZones()
{
    int write = 0;
    for (int read = 0; read < g_iZoneCount; read++)
    {
        if (g_iZoneOwner[read] == -1)
            continue;
        if (write != read)
            CopyZoneSlot(read, write);
        write++;
    }
    g_iZoneCount = write;
}

void RemoveClientZones(int client)
{
    int write = 0;
    for (int read = 0; read < g_iZoneCount; read++)
    {
        if (g_iZoneOwner[read] == client)
            continue;
        if (write != read)
            CopyZoneSlot(read, write);
        write++;
    }
    g_iZoneCount = write;
}

void CopyZoneSlot(int src, int dst)
{
    g_iZoneId[dst] = g_iZoneId[src];
    strcopy(g_sZoneName[dst], MAX_NAME_LEN, g_sZoneName[src]);
    g_fZoneP0[dst][0]      = g_fZoneP0[src][0];
    g_fZoneP0[dst][1]      = g_fZoneP0[src][1];
    g_fZoneP1[dst][0]      = g_fZoneP1[src][0];
    g_fZoneP1[dst][1]      = g_fZoneP1[src][1];
    g_fZoneP2[dst][0]      = g_fZoneP2[src][0];
    g_fZoneP2[dst][1]      = g_fZoneP2[src][1];
    g_fZoneThreshZ[dst]    = g_fZoneThreshZ[src];
    g_bZoneHasP2[dst]      = g_bZoneHasP2[src];
    g_bZoneThreshDown[dst] = g_bZoneThreshDown[src];
    g_bZoneIsDefault[dst]  = g_bZoneIsDefault[src];
    g_iZoneOwner[dst]      = g_iZoneOwner[src];
    strcopy(g_sZoneOwnerSteamId[dst], STEAMID_LEN, g_sZoneOwnerSteamId[src]);
}

// ===== Export / Import =====
public Action CmdExportZone(int client, int args)
{
    if (client == 0)
        return Plugin_Handled;

    int zoneIdx = -1;
    if (args >= 1)
    {
        char searchName[MAX_NAME_LEN];
        GetCmdArg(1, searchName, sizeof(searchName));
        for (int i = 0; i < g_iZoneCount; i++)
        {
            if ((g_iZoneOwner[i] == -1 || g_iZoneOwner[i] == client)
                && StrEqual(g_sZoneName[i], searchName, false))
            {
                zoneIdx = i;
                break;
            }
        }
        if (zoneIdx < 0)
        {
            GOKZ_PrintToChat(client, true, "{darkred}Zone {purple}\"%s\" {darkred}not found.", searchName);
            return Plugin_Handled;
        }
    }
    else
    {
        GOKZ_PrintToChat(client, true, "{darkred}Usage: {default}sm_miss_export <zone name>");
        return Plugin_Handled;
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMap(mapName, sizeof(mapName));

    char exportStr[1024];
    FormatEx(exportStr, sizeof(exportStr),
             "misszone;1;%s;%s;%f;%f;%f;%f;%f;%f;%f;%d;%d",
             mapName,
             g_sZoneName[zoneIdx],
             g_fZoneP0[zoneIdx][0], g_fZoneP0[zoneIdx][1],
             g_fZoneP1[zoneIdx][0], g_fZoneP1[zoneIdx][1],
             g_fZoneP2[zoneIdx][0], g_fZoneP2[zoneIdx][1],
             g_fZoneThreshZ[zoneIdx],
             g_bZoneHasP2[zoneIdx] ? 1 : 0,
             g_bZoneThreshDown[zoneIdx] ? 1 : 0);

    PrintToConsole(client, "=== Missedby Export ===");
    PrintToConsole(client, "%s", exportStr);
    PrintToConsole(client, "Use: sm_miss_import <string>");
    GOKZ_PrintToChat(client, true, "{default}Zone exported to console. Open console to copy.");
    return Plugin_Handled;
}

public Action CmdImportZone(int client, int args)
{
    if (client == 0)
        return Plugin_Handled;

    if (args < 1)
    {
        GOKZ_PrintToChat(client, true, "{darkred}Usage: {purple}sm_miss_import <export_string>");
        return Plugin_Handled;
    }

    char importStr[1024];
    GetCmdArgString(importStr, sizeof(importStr));

    // Parse: misszone;1;map;name;p0x;p0y;p1x;p1y;p2x;p2y;thresh_z;has_p2;thresh_down
    char parts[13][256];
    int  count = ExplodeString(importStr, ";", parts, 13, 256);
    if (count < 13 || !StrEqual(parts[0], "misszone") || !StrEqual(parts[1], "1"))
    {
        GOKZ_PrintToChat(client, true, "{darkred}Invalid import string.");
        return Plugin_Handled;
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMap(mapName, sizeof(mapName));
    if (!StrEqual(parts[2], mapName, false))
    {
        GOKZ_PrintToChat(client, true, "{darkred}Zone is for map {purple}%s{darkred}, not current map.", parts[2]);
        return Plugin_Handled;
    }

    // Populate workspace from parsed values and save
    g_fWsP0[client][0]      = StringToFloat(parts[4]);
    g_fWsP0[client][1]      = StringToFloat(parts[5]);
    g_fWsP1[client][0]      = StringToFloat(parts[6]);
    g_fWsP1[client][1]      = StringToFloat(parts[7]);
    g_fWsP2[client][0]      = StringToFloat(parts[8]);
    g_fWsP2[client][1]      = StringToFloat(parts[9]);
    g_fWsThreshZ[client]    = StringToFloat(parts[10]);
    g_bWsPosSet[client][0]  = true;
    g_bWsPosSet[client][1]  = true;
    g_bWsPosSet[client][2]  = StringToInt(parts[11]) != 0;
    g_bWsThreshDown[client] = StringToInt(parts[12]) != 0;

    DB_SaveZone(client, parts[3]);
    GOKZ_PrintToChat(client, true, "{default}Importing zone {purple}%s{default}...", parts[3]);
    return Plugin_Handled;
}
