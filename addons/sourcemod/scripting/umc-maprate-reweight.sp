/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
 *                            Ultimate Mapchooser - Map Rate Reweight                            *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

#pragma semicolon 1

#include <sourcemod>
#include <umc-core>
#include <umc_utils>

#undef REQUIRE_PLUGIN

//Auto update
#include <updater>
#if AUTOUPDATE_DEV
    #define UPDATE_URL "http://www.ccs.neu.edu/home/steell/sourcemod/ultimate-mapchooser/dev/updateinfo-umc-maprate-reweight.txt"
#else
    #define UPDATE_URL "http://www.ccs.neu.edu/home/steell/sourcemod/ultimate-mapchooser/updateinfo-umc-maprate-reweight.txt"
#endif

//Welcome to UMC Map Rate Reweight by Steell!
/**
 * This plugin is meant to serve as a functional and useful example of Ultimate Mapchooser's
 * dynamic map reweighting system. This system allows other plugins to affect how a map's weight
 * is calculated when UMC is performing it's randomization algorithm.
 */
public Plugin:myinfo =
{
    name = "[UMC] Map Rate Reweight",
    author = "Steell",
    description = "Reweights maps in UMC based off of their average rating in Map Rate.",
    version = PL_VERSION,
    url = "http://forums.alliedmods.net/showthread.php?t=134190"
}

#define SQL_STATEMENT "SELECT map, AVG(rating) FROM %s GROUP BY map HAVING COUNT(rating) >= %i"

/******** GLOBALS *********/

//Cvar
new Handle:cvar_min_votes = INVALID_HANDLE;
new Handle:cvar_scale     = INVALID_HANDLE;
new Handle:cvar_default   = INVALID_HANDLE;

//Our SQL information
new String:table_name[255];
new String:db_name[255];

//We are going to cache this information early on so that UMC isn't held up by an SQL query.
new Handle:map_ratings = INVALID_HANDLE;

//Flag stating if we're ready to reweight (do we have information in the cache?)
new bool:reweight = false;

/**************************/


//Initialize the cache.
public OnPluginStart()
{
    cvar_default = CreateConVar(
        "sm_umc_maprate_default",
        "3",
        "Weight given to maps that do not have the specified minimum amount of ratings.",
        0, true, 1.0
    );
    
    cvar_min_votes = CreateConVar(
        "sm_umc_maprate_minvotes",
        "5",
        "Minimum number of ratings required for a map in order for it to be reweighted.",
        0, true, 1.0
    );
    
    cvar_scale = CreateConVar(
        "sm_umc_maprate_expscale",
        "1.0",
        "Average rating for a map is scaled by this value before being used as a weight. Scaling is calculated using the following formula: weight(map) = avg_rating(map) ^ scale",
        0, true, 0.0
    );

    AutoExecConfig(true, "umc-maprate-reweight");
    
    RegAdminCmd(
        "sm_umc_maprate_testreweight", Command_TestReweight, ADMFLAG_CHANGEMAP,
        "Tests how Map Rate Reweighting will reweight a map.\nUsage: \"sm_umc_maprate_testreweight <map>\""
    );
    
    map_ratings = CreateTrie();

#if AUTOUPDATE_ENABLE
    if (LibraryExists("updater"))
    {
        Updater_AddPlugin(UPDATE_URL);
    }
#endif
}


#if AUTOUPDATE_ENABLE
//Called when a new API library is loaded. Used to register UMC auto-updating.
public OnLibraryAdded(const String:name[])
{
    if (StrEqual(name, "updater"))
    {
        Updater_AddPlugin(UPDATE_URL);
    }
}
#endif


//sm_umc_maprate_testreweight <map>
public Action:Command_TestReweight(client, args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "\x03[UMC]\x01 Usage: sm_umc_maprate_testreweight <map>");
    }
    else
    {
        decl String:map[MAP_LENGTH];
        GetCmdArg(1, map, sizeof(map));
        
        ReplyToCommand(
            client,
            "\x03[UMC]\x01 Map %s will be reweighted by a factor of %f",
            map, FetchMapWeight(map)
        );
    }
    return Plugin_Handled;
}


//Repopulate the cache on each map start.
public OnConfigsExecuted()
{
    new Handle:cvarTable = FindConVar("maprate_table");
    if (cvarTable == INVALID_HANDLE)
        cvarTable = FindConVar("sm_maprate_table");
    
    new Handle:cvarDbConfig = FindConVar("maprate_db_config");
    if (cvarDbConfig == INVALID_HANDLE)
        cvarDbConfig = FindConVar("sm_maprate_db_config");
        
    if (cvarTable != INVALID_HANDLE && cvarDbConfig != INVALID_HANDLE)
    {
        GetConVarString(cvarTable, table_name, sizeof(table_name));
        GetConVarString(cvarDbConfig, db_name, sizeof(db_name));
    
        if (SQL_CheckConfig(db_name))
            SQL_TConnect(Handle_SQLConnect, db_name);
        else
            LogError("Database configuration \"%s\" does not exist.", db_name);
    }
    else
    {
        LogError("Plugin \"Map Rate\" is not loaded, cannot determine which SQL table to look for ratings in.");
        SetFailState("Plugin \"Map Rate\" is not loaded.");
    }
}


//Handles the database connection
public Handle_SQLConnect(Handle:owner, Handle:db, const String:error[], any:data)
{
    if (db == INVALID_HANDLE)
    {
        LogError("Error establishing a database connection: %s", error);
        return;
    }
    
    new String:query[100];
    new bufferSize = sizeof(table_name) * 2 + 1;
    new String:tableName[bufferSize];
    
    SQL_QuoteString(db, table_name, tableName, bufferSize);
    Format(query, sizeof(query), SQL_STATEMENT, tableName, GetConVarInt(cvar_min_votes));
    
    SQL_TQuery(db, Handle_MapRatingQuery, query);
    
    CloseHandle(db);
}


//Handles the results of the query
public Handle_MapRatingQuery(Handle:owner, Handle:hQuery, const String:error[], any:data)
{
    if (hQuery == INVALID_HANDLE)
    {
        LogError("Unable to fetch maps from database: \"%s\"", error);
        return;
    }
    
    decl String:map[64];
    new Float:average;
    while (SQL_FetchRow(hQuery))
    {
        SQL_FetchString(hQuery, 0, map, sizeof(map));
        average = SQL_FetchFloat(hQuery, 1);
        
        SetTrieValue(map_ratings, map, average);
    }
    reweight = true;  
}


//
Float:FetchMapWeight(const String:map[])
{
    new Float:weight;
    if (GetTrieValue(map_ratings, map, weight))
    {
        return Pow(weight, GetConVarFloat(cvar_scale));
    }
    else
    {
        return GetConVarFloat(cvar_default);
    }
}


//Reweights a map when UMC requests,
public UMC_OnReweightMap(Handle:kv, const String:map[], const String:group[])
{
    if (!reweight) return;
    
    new Float:weight = FetchMapWeight(map);
    UMC_AddWeightModifier(weight);
    
#if UMC_DEBUG
    LogUMCMessage("Map %s was reweighted by %f", map, weight);
#endif
}

