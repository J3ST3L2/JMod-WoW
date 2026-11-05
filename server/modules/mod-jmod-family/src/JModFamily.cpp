// JMod family travel for AzerothCore WotLK 3.3.5a.
// All commands are SEC_PLAYER. No GM permissions, SQL writes, or forced summons.
#include "AccountMgr.h"
#include "Chat.h"
#include "CommandScript.h"
#include "Group.h"
#include "Map.h"
#include "MapMgr.h"
#include "ObjectAccessor.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "PlayerScript.h"
#include "Util.h"
#include "WorldSession.h"

#include <chrono>
#include <map>
#include <string>
#include <utility>

using namespace Acore::ChatCommands;

namespace
{
using Clock = std::chrono::steady_clock;
using Time = Clock::time_point;

constexpr auto RequestLifetime = std::chrono::seconds(60);
constexpr auto RequestCooldown = std::chrono::seconds(10);
constexpr auto HubCooldown = std::chrono::seconds(30);

enum class Trip { Go, Summon };

struct Request
{
    ObjectGuid requester;
    Trip trip;
    Time expires;
};

// Keyed by the player who must explicitly accept the request.
// These collections are used on the world thread by chat and logout hooks.
std::map<ObjectGuid, Request> requests;
std::map<ObjectGuid, Time> lastRequest;
std::map<ObjectGuid, Time> lastHub;

void Tell(Player* player, std::string const& text)
{
    if (player && player->GetSession())
        ChatHandler(player->GetSession()).SendSysMessage("[JMod Family] " + text);
}

bool IsWorldMap(uint32 map)
{
    // Azeroth, Kalimdor, Outland, Northrend. Never instances, arenas or BGs.
    return map == 0 || map == 1 || map == 530 || map == 571;
}

bool CanTravel(Player* player)
{
    return player && player->IsInWorld() && player->IsAlive()
        && !player->IsInCombat() && !player->IsBeingTeleported()
        && !player->IsInFlight() && !player->GetTransport()
        && !player->GetVehicle() && !player->IsSpectator()
        && player->GetMap() && !player->GetMap()->Instanceable()
        && IsWorldMap(player->GetMapId());
}

bool InSameParty(Player* first, Player* second)
{
    if (!first || !second || first == second)
        return false;

    Group* group = first->GetGroup();
    return group && group == second->GetGroup()
        && !group->isBGGroup() && !group->isBFGroup()
        && !group->isLFGGroup();
}

void PruneExpired()
{
    Time const now = Clock::now();
    for (auto it = requests.begin(); it != requests.end();)
        if (it->second.expires <= now)
            it = requests.erase(it);
        else
            ++it;
}

bool TeleportPlayer(Player* passenger, Player* destination)
{
    if (!CanTravel(passenger) || !CanTravel(destination)
        || !InSameParty(passenger, destination))
        return false;

    uint32 const map = destination->GetMapId();
    float const x = destination->GetPositionX();
    float const y = destination->GetPositionY();
    float const z = destination->GetPositionZ();
    float const o = destination->GetOrientation();

    if (!MapMgr::IsValidMapCoord(map, x, y, z, o))
        return false;

    passenger->SaveRecallPosition();
    return passenger->TeleportTo(map, x, y, z, o);
}

bool RequestTravel(ChatHandler* handler, std::string name, Trip trip)
{
    Player* requester = handler->GetPlayer();
    if (!requester)
        return false;

    if (!normalizePlayerName(name))
    {
        handler->SendSysMessage("Enter a valid online character name.");
        return true;
    }

    Player* recipient = ObjectAccessor::FindPlayerByName(name, false);
    if (!recipient || recipient == requester)
    {
        handler->SendSysMessage("That player is not online.");
        return true;
    }

    if (!InSameParty(requester, recipient))
    {
        handler->SendSysMessage("You must both be in the same regular party or raid.");
        return true;
    }

    if (!CanTravel(requester) || !CanTravel(recipient))
    {
        handler->SendSysMessage("Travel is unavailable during combat, flight, transport, or in an instance/battleground.");
        return true;
    }

    PruneExpired();
    Time const now = Clock::now();
    if (auto it = lastRequest.find(requester->GetGUID()); it != lastRequest.end()
        && now - it->second < RequestCooldown)
    {
        handler->SendSysMessage("Please wait 10 seconds between travel requests.");
        return true;
    }

    if (requests.find(recipient->GetGUID()) != requests.end())
    {
        handler->SendSysMessage("That player already has a pending travel request.");
        return true;
    }

    requests.emplace(recipient->GetGUID(), Request{requester->GetGUID(), trip, now + RequestLifetime});
    lastRequest[requester->GetGUID()] = now;

    if (trip == Trip::Go)
    {
        Tell(recipient, requester->GetName() + " wants to travel to you. Use /family and Accept Request, or type .jmodfamily accept / .jmodfamily decline. Expires in 60 seconds.");
        Tell(requester, "Asked " + recipient->GetName() + " to let you travel to them.");
    }
    else
    {
        Tell(recipient, requester->GetName() + " wants to summon you to their location. Use /family and Accept Request, or type .jmodfamily accept / .jmodfamily decline. Expires in 60 seconds.");
        Tell(requester, "Asked " + recipient->GetName() + " to travel to you.");
    }
    return true;
}

bool HandleAccept(ChatHandler* handler)
{
    Player* recipient = handler->GetPlayer();
    if (!recipient)
        return false;

    auto it = requests.find(recipient->GetGUID());
    if (it == requests.end())
    {
        handler->SendSysMessage("No pending family travel request.");
        return true;
    }

    Request const request = it->second;
    requests.erase(it); // one-time consent, even on failure

    if (request.expires <= Clock::now())
    {
        handler->SendSysMessage("That travel request expired.");
        return true;
    }

    Player* requester = ObjectAccessor::FindConnectedPlayer(request.requester);
    if (!requester || !InSameParty(requester, recipient)
        || !CanTravel(requester) || !CanTravel(recipient))
    {
        handler->SendSysMessage("Travel is no longer available. Both players must be online, grouped and in a safe location.");
        return true;
    }

    Player* passenger = request.trip == Trip::Go ? requester : recipient;
    Player* destination = request.trip == Trip::Go ? recipient : requester;
    if (!TeleportPlayer(passenger, destination))
    {
        handler->SendSysMessage("Teleport failed; your current locations may be restricted.");
        Tell(requester, "Travel failed; please try again from a safe outdoor area.");
        return true;
    }

    Tell(requester, "Travel request accepted by " + recipient->GetName() + ".");
    Tell(recipient, "Travel request accepted.");
    return true;
}

bool HandleDecline(ChatHandler* handler)
{
    Player* recipient = handler->GetPlayer();
    if (!recipient)
        return false;

    auto it = requests.find(recipient->GetGUID());
    if (it == requests.end())
    {
        handler->SendSysMessage("No pending family travel request.");
        return true;
    }

    ObjectGuid const requesterGuid = it->second.requester;
    requests.erase(it);
    Tell(recipient, "Travel declined.");
    Tell(ObjectAccessor::FindConnectedPlayer(requesterGuid), recipient->GetName() + " declined the travel request.");
    return true;
}

bool HandleHub(ChatHandler* handler, std::string city)
{
    Player* player = handler->GetPlayer();
    if (!player)
        return false;

    if (!CanTravel(player))
    {
        handler->SendSysMessage("Travel is unavailable during combat, flight, transport or in an instance/battleground.");
        return true;
    }

    if (city == "stormwind" && player->GetTeamId() != TEAM_ALLIANCE)
    {
        handler->SendSysMessage("Stormwind is for Alliance characters.");
        return true;
    }
    if (city == "orgrimmar" && player->GetTeamId() != TEAM_HORDE)
    {
        handler->SendSysMessage("Orgrimmar is for Horde characters.");
        return true;
    }

    if (city != "dalaran" && city != "shattrath"
        && city != "stormwind" && city != "orgrimmar")
    {
        handler->SendSysMessage("Allowed hubs: dalaran, shattrath, stormwind, orgrimmar.");
        return true;
    }

    GameTele const* location = sObjectMgr->GetGameTele(city, true);
    if (!location || !IsWorldMap(location->mapId)
        || !MapMgr::IsValidMapCoord(location->mapId, location->position_x,
                                   location->position_y, location->position_z,
                                   location->orientation))
    {
        handler->SendSysMessage("No safe teleport location is configured for that hub.");
        return true;
    }

    Time const now = Clock::now();
    if (auto it = lastHub.find(player->GetGUID()); it != lastHub.end()
        && now - it->second < HubCooldown)
    {
        handler->SendSysMessage("Please wait 30 seconds between hub teleports.");
        return true;
    }

    player->SaveRecallPosition();
    if (!player->TeleportTo(location->mapId, location->position_x,
                            location->position_y, location->position_z,
                            location->orientation))
    {
        handler->SendSysMessage("Teleport could not be completed.");
        return true;
    }

    lastHub[player->GetGUID()] = now;
    Tell(player, "Traveling to " + city + ".");
    return true;
}
}

class jmod_family_commands : public CommandScript
{
public:
    jmod_family_commands() : CommandScript("jmod_family_commands") {}

    ChatCommandTable GetCommands() const override
    {
        static ChatCommandTable const actions =
        {
            {"go",      HandleGo,      SEC_PLAYER, Console::No},
            {"summon",  HandleSummon,  SEC_PLAYER, Console::No},
            {"accept",  HandleAccept,  SEC_PLAYER, Console::No},
            {"decline", HandleDecline, SEC_PLAYER, Console::No},
            {"hub",     HandleHub,     SEC_PLAYER, Console::No}
        };
        return {{"jmodfamily", actions}};
    }

    static bool HandleGo(ChatHandler* handler, std::string const& name)
    {
        return RequestTravel(handler, name, Trip::Go);
    }

    static bool HandleSummon(ChatHandler* handler, std::string const& name)
    {
        return RequestTravel(handler, name, Trip::Summon);
    }

    static bool HandleAccept(ChatHandler* handler) { return ::HandleAccept(handler); }
    static bool HandleDecline(ChatHandler* handler) { return ::HandleDecline(handler); }
    static bool HandleHub(ChatHandler* handler, std::string const& city)
    {
        return ::HandleHub(handler, city);
    }
};

class jmod_family_cleanup : public PlayerScript
{
public:
    jmod_family_cleanup() : PlayerScript("jmod_family_cleanup") {}

    void OnPlayerLogout(Player* player) override
    {
        ObjectGuid const guid = player->GetGUID();
        requests.erase(guid);
        lastRequest.erase(guid);
        lastHub.erase(guid);
        for (auto it = requests.begin(); it != requests.end();)
            if (it->second.requester == guid)
                it = requests.erase(it);
            else
                ++it;
    }
};

void AddSC_JModFamily()
{
    new jmod_family_commands();
    new jmod_family_cleanup();
}
