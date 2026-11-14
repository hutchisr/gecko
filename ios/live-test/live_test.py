"""Live two-account check of Gecko against a real XMPP server.

Gecko runs in a booted Simulator (GECKO_SIM_DEVICE when several are), signed in as USERNAME from
credentials.local.txt, and is driven by its DINO_* launch hooks. This script
signs in as USERNAME2 and plays the other person: it sends and answers contact
requests, exchanges plain and OMEMO messages, shares a room and files, and checks
what Gecko put on the wire. Gecko's side is read from the `gecko-live:` lines
that AppModel logs with DINO_LIVE_TEST=1.

Run with ios/live-test/run.sh; see ios/PORTING.md for setup.
"""

import argparse
import asyncio
import json
import os
import re
import secrets
import sqlite3
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, FrozenSet, List, Optional, Tuple

import oldmemo
from omemo.storage import Just, Maybe, Nothing, Storage
from omemo.types import DeviceInformation, JSONType
from slixmpp import JID, ClientXMPP
from slixmpp.plugins import register_plugin
from slixmpp.stanza import Message
from slixmpp.xmlstream.handler import Callback
from slixmpp.xmlstream.matcher import MatchXPath
from slixmpp_omemo import XEP_0384

ROOT = Path(__file__).resolve().parents[2]
STATE = Path(__file__).resolve().parent / ".state"
BUNDLE = "me.anemoneya.gecko"
#: The Simulator to drive; set from GECKO_SIM_DEVICE or the only booted one.
DEVICE = "booted"


def pick_device() -> str:
    """With several Simulators booted, "booted" means any of them: refuse to guess."""
    import subprocess
    if os.environ.get("GECKO_SIM_DEVICE"):
        return os.environ["GECKO_SIM_DEVICE"]
    listing = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "booted", "-j"],
                                        capture_output=True, text=True, check=True).stdout)
    booted = [d for devices in listing["devices"].values() for d in devices if d["state"] == "Booted"]
    if len(booted) != 1:
        names = ", ".join(f"{d['name']} ({d['udid']})" for d in booted) or "none"
        sys.exit(f"Set GECKO_SIM_DEVICE to one Simulator; booted: {names}")
    return booted[0]["udid"]
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def credentials() -> Dict[str, str]:
    lines = (ROOT / "credentials.local.txt").read_text().splitlines()
    return dict(line.split("=", 1) for line in lines if "=" in line)


# --- OMEMO for the peer (python-omemo, blind trust before verification) ---

class JsonStorage(Storage):
    def __init__(self, path: Path) -> None:
        super().__init__()
        self.path = path
        self.data: Dict[str, JSONType] = json.loads(path.read_text()) if path.exists() else {}

    async def _load(self, key: str) -> Maybe[JSONType]:
        return Just(self.data[key]) if key in self.data else Nothing()

    async def _store(self, key: str, value: JSONType) -> None:
        self.data[key] = value
        self.path.write_text(json.dumps(self.data))

    async def _delete(self, key: str) -> None:
        self.data.pop(key, None)
        self.path.write_text(json.dumps(self.data))


class PeerOmemo(XEP_0384):
    default_config = {"fallback_message": "This message is OMEMO encrypted.", "json_file_path": None}

    def plugin_init(self) -> None:
        self._json_storage = JsonStorage(Path(self.json_file_path))
        super().plugin_init()

    @property
    def storage(self) -> Storage:
        return self._json_storage

    @property
    def _btbv_enabled(self) -> bool:
        return True

    async def _devices_blindly_trusted(self, blindly_trusted: FrozenSet[DeviceInformation],
                                       identifier: Optional[str]) -> None:
        pass

    async def _prompt_manual_trust(self, manually_trusted: FrozenSet[DeviceInformation],
                                   identifier: Optional[str]) -> None:
        raise RuntimeError(f"unexpected manual trust prompt for {manually_trusted}")


register_plugin(PeerOmemo)


# --- The two sides ---

class Peer(ClientXMPP):
    """USERNAME2: records every message and presence it receives."""

    def __init__(self, jid: str, password: str) -> None:
        super().__init__(jid, password)
        self.messages: List[Message] = []
        self.presences: List[Any] = []
        self.ready = asyncio.Event()
        self.add_event_handler("session_start", self.start)
        # Every <message/>: slixmpp's "message" event skips those without a body
        # (markers, reactions, chat states).
        self.register_handler(Callback("all messages", MatchXPath("{jabber:client}message"),
                                       lambda m: self.messages.append(m)))
        # Every <presence/> too: slixmpp's room plugin takes some for itself.
        self.register_handler(Callback("all presences", MatchXPath("{jabber:client}presence"),
                                       lambda p: self.presences.append(p)))
        # Jingle requests (calls), answered by the steps themselves; slixmpp
        # would otherwise refuse them.
        self.jingle: List[Any] = []
        self.register_handler(Callback("jingle", MatchXPath("{jabber:client}iq/{urn:xmpp:jingle:1}jingle"),
                                       lambda iq: self.jingle.append(iq)))

    async def start(self, _: Any) -> None:
        self.send_presence()
        await self.get_roster()
        self.ready.set()

    def subscription(self, jid: str) -> str:
        return self.client_roster[jid]["subscription"] if jid in self.client_roster else "none"


class App:
    """One launch of Gecko in the Simulator, with its `gecko-live:` events."""

    #: Extra launch environment for every launch (`--log`).
    common: Dict[str, str] = {}
    #: Keep each launch's console in .state/launch-N.log (`--log`).
    log = False
    launches = 0

    def __init__(self, env: Dict[str, str]) -> None:
        self.env = {"DINO_LIVE_TEST": "1", **App.common, **env}
        self.events: List[Dict[str, Any]] = []
        self.proc: Optional[asyncio.subprocess.Process] = None
        self.reader: Optional[asyncio.Task] = None

    async def __aenter__(self) -> "App":
        child = {f"SIMCTL_CHILD_{k}": v for k, v in self.env.items()}
        self.proc = await asyncio.create_subprocess_exec(
            "xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", DEVICE, BUNDLE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, env={**os.environ, **child},
            # Stanza logs carry long lines; a reader that gives up stalls the app.
            limit=16 * 1024 * 1024)
        self.reader = asyncio.create_task(self.read())
        return self

    async def read(self) -> None:
        assert self.proc and self.proc.stdout
        App.launches += 1
        log = (STATE / f"launch-{App.launches}.log").open("w") if App.log else None
        async for raw in self.proc.stdout:
            line = ANSI.sub("", raw.decode(errors="replace"))
            if log:
                log.write(line)
            if "gecko-live: " in line:
                try:
                    self.events.append(json.loads(line.split("gecko-live: ", 1)[1]))
                except json.JSONDecodeError:
                    pass

    async def __aexit__(self, *_: Any) -> None:
        await (await asyncio.create_subprocess_exec("xcrun", "simctl", "terminate", DEVICE, BUNDLE,
                                                    stderr=asyncio.subprocess.DEVNULL)).wait()
        if self.proc and self.proc.returncode is None:
            self.proc.terminate()
        if self.reader:
            self.reader.cancel()

    def find(self, **want: Any) -> Optional[Dict[str, Any]]:
        return next((e for e in self.events if all(e.get(k) == v for k, v in want.items())), None)


async def until(what: str, check: Callable[[], Any], timeout: float = 45) -> Any:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found = check()
        # An XML element without children is falsy, but it is a find.
        if found is not None and found is not False:
            return found
        await asyncio.sleep(0.5)
    raise AssertionError(f"timed out waiting for {what}")


def from_app(peer: Peer, app_jid: str, body: str) -> Callable[[], Optional[Message]]:
    return lambda: next((m for m in peer.messages
                         if m["from"].bare == app_jid and (m["body"] == body or body in str(m))), None)


# --- Steps ---

async def reset(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """Neither side has the other as a contact."""
    if app_jid in peer.client_roster:
        await peer.del_roster_item(app_jid)
    async with App({"DINO_AUTOREMOVECONTACT": peer_jid}):
        await asyncio.sleep(14)
    await until("peer to drop the contact", lambda: peer.subscription(app_jid) == "none")


async def contact_request(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """The peer asks; Gecko shows the request, accepts it and asks back."""
    peer.send_presence(pto=app_jid, ptype="subscribe")
    async with App({"DINO_AUTOACCEPT": peer_jid}) as app:
        await until("Gecko to show the request", lambda: app.find(type="subscription_request", jid=peer_jid))
        await until("a mutual subscription on the peer", lambda: peer.subscription(app_jid) == "both")
        await until("Gecko's roster to list the peer as mutual",
                    lambda: any(f"{peer_jid}:both" in e.get("list", []) for e in app.events if e["type"] == "roster"))


async def plain_messages(peer: Peer, app_jid: str, peer_jid: str) -> None:
    out, back = f"plain-out-{secrets.token_hex(4)}", f"plain-in-{secrets.token_hex(4)}"
    async with App({"DINO_AUTOPEER": peer_jid, "DINO_AUTOOMEMO": "0", "DINO_AUTOSEND": out}) as app:
        message = await until("Gecko's message at the peer", from_app(peer, app_jid, out))
        assert not peer.plugin["xep_0384"].is_encrypted(message), "a plain message arrived encrypted"
        peer.send_message(mto=app_jid, mbody=back, mtype="chat")
        await until("the peer's message in Gecko",
                    lambda: app.find(type="message", direction="in", body=back, jid=peer_jid))


async def next_encrypted(peer: Peer, sender: str, seen: int, timeout: float = 60) -> Tuple[Message, Message]:
    """The first OMEMO message from `sender` after `peer.messages[seen]` that
    carries a body (skipping bodiless key-transport ones): (wire, decrypted)."""
    omemo, deadline = peer.plugin["xep_0384"], time.monotonic() + timeout
    while True:
        assert time.monotonic() < deadline, f"timed out waiting for an encrypted message from {sender}"
        if seen < len(peer.messages):
            candidate, seen = peer.messages[seen], seen + 1
            if candidate["from"].bare == sender and omemo.is_encrypted(candidate):
                try:
                    decrypted, _ = await omemo.decrypt_message(candidate)
                except Exception as error:
                    raise AssertionError(f"{error} for {str(candidate)[:900]}") from error
                if decrypted["body"]:
                    return candidate, decrypted
        else:
            await asyncio.sleep(0.5)


async def omemo_messages(peer: Peer, app_jid: str, peer_jid: str) -> None:
    out, back = f"omemo-out-{secrets.token_hex(4)}", f"omemo-in-{secrets.token_hex(4)}"
    omemo: XEP_0384 = peer.plugin["xep_0384"]
    seen = len(peer.messages)
    async with App({"DINO_AUTOPEER": peer_jid, "DINO_AUTOOMEMO": "1", "DINO_AUTOSEND": out}) as app:
        encrypted, decrypted = await next_encrypted(peer, app_jid, seen)
        assert out not in str(encrypted), "the plaintext was on the wire"
        assert decrypted["body"] == out, f"decrypted {decrypted['body']!r}, sent {out!r}"
        reply = peer.make_message(mto=JID(app_jid), mtype="chat")
        reply["body"] = back
        message, _ = await omemo.encrypt_message(reply, {JID(app_jid)})
        message["eme"]["namespace"] = oldmemo.oldmemo.NAMESPACE
        message["eme"]["name"] = peer.plugin["xep_0380"].mechanisms[oldmemo.oldmemo.NAMESPACE]
        message.send()
        event = await until("the peer's encrypted message in Gecko",
                            lambda: app.find(type="message", direction="in", body=back, jid=peer_jid), timeout=60)
        assert event.get("encryption") not in (None, "NONE"), f"shown as {event.get('encryption')}"


async def group_chat(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """Gecko joins a room, sees its members, and talks in it both ways; then the
    peer invites Gecko to a second room and Gecko accepts."""
    muc = peer.plugin["xep_0045"]
    service = muc.muc_service or "muc.xmpp.is"
    room, second = (f"gecko-live-{secrets.token_hex(4)}@{service}" for _ in range(2))
    said, answered = f"room-{secrets.token_hex(4)}", f"room-reply-{secrets.token_hex(4)}"
    for jid in (room, second):
        await muc.join_muc_wait(JID(jid), "peer", maxstanzas=0)
        instant = peer.make_iq_set(ito=jid)
        instant.append(instant_room_form())
        await instant.send()
    try:
        async with App({"DINO_AUTOJOINMUC": room, "DINO_AUTOROOMSEND": answered}) as app:
            await until("Gecko in the room", lambda: len(muc.get_roster(JID(room)) or []) >= 2)
            await until("the peer among the room's members in Gecko", lambda: any(
                e["type"] == "occupants" and e.get("jid") == room and "peer" in e.get("nicks", []) for e in app.events))
            peer.send_message(mto=room, mbody=said, mtype="groupchat")
            await until("the room message in Gecko", lambda: app.find(type="message", body=said, jid=room))
            await until("Gecko's message in the room", lambda: any(
                m["type"] == "groupchat" and m["from"].bare == room and m["body"] == answered for m in peer.messages))
        async with App({"DINO_AUTOCLOSE": room}):
            await asyncio.sleep(12)

        async with App({"DINO_AUTOJOININVITE": "1"}) as app:
            await until("Gecko online", lambda: app.find(type="connection", state="CONNECTED"))
            await asyncio.sleep(3)
            muc.invite(JID(second), JID(app_jid), reason="come along")
            await until("the invitation in Gecko", lambda: app.find(type="muc_invite", room=second))
            await until("Gecko in the invited room", lambda: app.find(type="muc_invite_joined", room=second))
            await until("Gecko among the second room's members", lambda: len(muc.get_roster(JID(second)) or []) >= 2)
        async with App({"DINO_AUTOCLOSE": second}):
            await asyncio.sleep(12)
    finally:
        for jid in (room, second):
            muc.leave_muc(JID(jid), "peer")


async def private_room(peer: Peer, members: List[str]) -> str:
    """A members-only room showing real JIDs, owned by the peer, with these members."""
    muc = peer.plugin["xep_0045"]
    room = f"gecko-private-{secrets.token_hex(4)}@{muc.muc_service or 'muc.xmpp.is'}"
    await muc.join_muc_wait(JID(room), "peer", maxstanzas=0)
    form = await muc.get_room_config(JID(room))
    values = {"muc#roomconfig_membersonly": True, "muc#roomconfig_whois": "anyone"}
    form["type"] = "submit"
    for name, field in list(form.get_fields().items()):
        if name in values:
            field["value"] = values[name]
    await muc.set_room_config(JID(room), form)
    for member in members:
        await muc.set_affiliation(JID(room), "member", jid=JID(member))
    return room


async def room_omemo(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """OMEMO in a private room, both ways."""
    muc, omemo = peer.plugin["xep_0045"], peer.plugin["xep_0384"]
    room = await private_room(peer, [app_jid])
    seen = len(peer.messages)
    sent, back = f"room-omemo-out-{secrets.token_hex(3)}", f"room-omemo-in-{secrets.token_hex(3)}"
    try:
        async with App({"DINO_AUTOJOINMUC": room, "DINO_AUTOROOMSEND": sent, "DINO_AUTOROOMOMEMO": "1"}) as app:
            await until("Gecko in the private room", lambda: len(muc.get_roster(JID(room)) or []) >= 2)
            encrypted, decrypted = await next_encrypted(peer, room, seen)
            assert encrypted["from"].resource != "peer", "our own reflection"
            assert sent not in str(encrypted), "the plaintext was on the wire"
            assert decrypted["body"] == sent, f"decrypted {decrypted['body']!r}"
            reply = peer.make_message(mto=JID(room), mtype="groupchat")
            reply["body"] = back
            message, _ = await omemo.encrypt_message(reply, {JID(app_jid), JID(peer_jid)})
            message["eme"]["namespace"] = oldmemo.oldmemo.NAMESPACE
            message["eme"]["name"] = peer.plugin["xep_0380"].mechanisms[oldmemo.oldmemo.NAMESPACE]
            message.send()
            event = await until("the peer's encrypted room message in Gecko",
                                lambda: app.find(type="message", body=back, jid=room), timeout=60)
            assert event.get("encryption") not in (None, "NONE")
        async with App({"DINO_AUTOCLOSE": room}):
            await asyncio.sleep(12)
    finally:
        muc.leave_muc(JID(room), "peer")


async def room_admin(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """Gecko creates a room, renames it, and removes a member."""
    muc = peer.plugin["xep_0045"]
    room = f"gecko-owned-{secrets.token_hex(4)}@{muc.muc_service or 'muc.xmpp.is'}"
    name = f"Gecko room {secrets.token_hex(2)}"
    async with App({"DINO_AUTOCREATEMUC": room, "DINO_AUTOROOMNAME": name, "DINO_AUTOROOMKICK": "peer"}):
        await asyncio.sleep(10)
        await muc.join_muc_wait(JID(room), "peer", maxstanzas=0)
        async def named() -> bool:
            info = await peer.plugin["xep_0030"].get_info(jid=JID(room))
            return any(identity[3] == name for identity in info["disco_info"]["identities"])
        deadline = time.monotonic() + 20
        while not await named():
            assert time.monotonic() < deadline, "the room was not renamed"
            await asyncio.sleep(1)
        await until("the peer removed from the room", lambda: any(
            p["from"].bare == room and p["from"].resource == "peer" and p["type"] == "unavailable"
            and "307" in str(p) for p in peer.presences), timeout=30)
    async with App({"DINO_AUTOCLOSE": room}):
        await asyncio.sleep(12)


def instant_room_form() -> Any:
    from xml.etree import ElementTree as ET
    query = ET.Element("{http://jabber.org/protocol/muc#owner}query")
    ET.SubElement(query, "{jabber:x:data}x", {"type": "submit"})
    return query


async def files(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """Gecko uploads an image to the peer; the peer uploads one back."""
    async with App({"DINO_AUTOPEER": peer_jid, "DINO_AUTOOMEMO": "0", "DINO_AUTOSENDFILE": "1"}) as app:
        message = await until("Gecko's file at the peer", lambda: next(
            (m for m in peer.messages if m["from"].bare == app_jid and m["oob"]["url"]), None), timeout=90)
        url = message["oob"]["url"]
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read()
        assert data.startswith(b"\x89PNG"), f"{url} is not the PNG Gecko sent"

        sent = STATE / "peer-upload.png"
        sent.write_bytes(data)
        url = await peer.plugin["xep_0363"].upload_file(sent, content_type="image/png")
        reply = peer.make_message(mto=app_jid, mbody=url, mtype="chat")
        reply["oob"]["url"] = url
        reply.send()
        await until("the peer's file in Gecko",
                    lambda: app.find(type="message", direction="in", content="file", jid=peer_jid), timeout=60)


async def omemo_files(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """Encrypted files (aesgcm:// links in OMEMO messages), both ways."""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    omemo = peer.plugin["xep_0384"]
    seen = len(peer.messages)
    async with App({"DINO_AUTOPEER": peer_jid, "DINO_AUTOOMEMO": "1", "DINO_AUTOSENDFILE": "1"}) as app:
        _, message = await next_encrypted(peer, app_jid, seen, timeout=90)
        link = message["body"]
        assert link.startswith("aesgcm://") and not message["oob"]["url"], f"not an encrypted link: {link!r}"
        location, fragment = link[len("aesgcm://"):].split("#", 1)
        secret = bytes.fromhex(fragment)
        with urllib.request.urlopen("https://" + location, timeout=30) as response:
            sealed = response.read()
        assert not sealed.startswith(b"\x89PNG"), "the server got the file in the clear"
        data = AESGCM(secret[-32:]).decrypt(secret[:-32], sealed, None)
        assert data.startswith(b"\x89PNG"), "Gecko's file did not decrypt to its PNG"

        key, iv = AESGCM.generate_key(256), secrets.token_bytes(12)
        upload = STATE / "peer-secret.png"
        upload.write_bytes(AESGCM(key).encrypt(iv, data, None))
        url = await peer.plugin["xep_0363"].upload_file(upload, content_type="application/octet-stream")
        reply = peer.make_message(mto=JID(app_jid), mtype="chat")
        reply["body"] = "aesgcm://" + url[len("https://"):] + "#" + (iv + key).hex()
        sent, _ = await omemo.encrypt_message(reply, {JID(app_jid)})
        sent["eme"]["namespace"] = oldmemo.oldmemo.NAMESPACE
        sent["eme"]["name"] = peer.plugin["xep_0380"].mechanisms[oldmemo.oldmemo.NAMESPACE]
        sent.send()
        await until("the peer's encrypted file in Gecko", lambda: app.find(
            type="message", direction="in", content="file", jid=peer_jid, file_name="peer-secret.png"), timeout=60)
        await until("the peer's encrypted file fetched and decrypted in Gecko", lambda: app.find(
            type="message", direction="in", content="file", jid=peer_jid, file_state="complete"), timeout=60)


def stanza_child(message: Message, name: str, ns: str):
    return message.xml.find(f"{{{ns}}}{name}")


def origin_id(message: Message) -> str:
    """The sender's own id for a message (XEP-0359), else its stanza id."""
    origin = stanza_child(message, "origin-id", "urn:xmpp:sid:0")
    return origin.get("id") if origin is not None else message["id"]


async def peer_message(peer: Peer, to: str, body: str, *extra) -> str:
    """Sends a markable chat message with an origin id; returns that id."""
    from xml.etree import ElementTree as ET
    msg = peer.make_message(mto=to, mbody=body, mtype="chat")
    origin = secrets.token_hex(6)
    msg["id"] = origin
    ET.SubElement(msg.xml, "{urn:xmpp:sid:0}origin-id", {"id": origin})
    ET.SubElement(msg.xml, "{urn:xmpp:chat-markers:0}markable")
    for element in extra:
        msg.xml.append(element)
    msg.send()
    return origin


async def message_extras(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """Read markers, reactions, replies and corrections, both ways, and typing."""
    from xml.etree import ElementTree as ET
    plain = {"DINO_AUTOPEER": peer_jid, "DINO_AUTOOMEMO": "0"}

    # Gecko opens the chat: it marks the peer's message displayed, then reacts.
    target = await peer_message(peer, app_jid, f"react-to-me-{secrets.token_hex(3)}")
    async with App({**plain, "DINO_AUTOREACT": "👍"}):
        await until("a displayed marker for the peer's message", lambda: any(
            (d := stanza_child(m, "displayed", "urn:xmpp:chat-markers:0")) is not None and d.get("id") == target
            for m in peer.messages if m["from"].bare == app_jid))
        reaction = await until("Gecko's reaction", lambda: next(
            (r for m in peer.messages if m["from"].bare == app_jid
             and (r := stanza_child(m, "reactions", "urn:xmpp:reactions:0")) is not None), None))
        assert reaction.get("id") == target, f"reacted to {reaction.get('id')}, not {target}"
        assert [e.text for e in reaction] == ["👍"], [e.text for e in reaction]

    # Gecko replies to it.
    replied = f"reply-{secrets.token_hex(3)}"
    async with App({**plain, "DINO_AUTOREPLY": replied}):
        reply_message = await until("Gecko's reply", from_app(peer, app_jid, replied))
        reply = stanza_child(reply_message, "reply", "urn:xmpp:reply:0")
        assert reply is not None and reply.get("id") == target, "the reply does not point at the message"

    # Gecko sends, then corrects its own message.
    sent, fixed = f"typo-{secrets.token_hex(3)}", f"fixed-{secrets.token_hex(3)}"
    async with App({**plain, "DINO_AUTOSEND": sent, "DINO_AUTOCORRECT": fixed}):
        original = await until("Gecko's message", from_app(peer, app_jid, sent))
        correction = await until("Gecko's correction", from_app(peer, app_jid, fixed))
        replace = stanza_child(correction, "replace", "urn:xmpp:message-correct:0")
        original_id = origin_id(original)
        assert replace is not None and replace.get("id") == original_id, "the correction does not replace it"

    # The peer types, corrects its message and reads Gecko's: Gecko shows all three.
    fresh = f"read-me-{secrets.token_hex(3)}"
    async with App({**plain, "DINO_AUTOSEND": fresh}) as app:
        await until("Gecko online", lambda: app.find(type="connection", state="CONNECTED"))
        await asyncio.sleep(4)
        typing = peer.make_message(mto=app_jid, mtype="chat")
        ET.SubElement(typing.xml, "{http://jabber.org/protocol/chatstates}composing")
        typing.send()
        await until("Gecko to show typing", lambda: app.find(type="chat_state", state="composing", jid=peer_jid))
        corrected = f"corrected-{secrets.token_hex(3)}"
        await peer_message(peer, app_jid, corrected, ET.Element(
            "{urn:xmpp:message-correct:0}replace", {"id": target}))
        await until("the corrected text in Gecko", lambda: app.find(type="message", body=corrected, jid=peer_jid))
        sent_now = await until("Gecko's fresh message", from_app(peer, app_jid, fresh))
        mine = origin_id(sent_now)
        read = peer.make_message(mto=app_jid, mtype="chat")
        ET.SubElement(read.xml, "{urn:xmpp:chat-markers:0}displayed", {"id": mine})
        read.send()
        await until("Gecko to show its message read",
                    lambda: app.find(type="message", marked="read", body=fresh, jid=peer_jid))


def app_group() -> Path:
    return Path(subprocess.run(["xcrun", "simctl", "get_app_container", DEVICE, BUNDLE, "group.me.anemoneya.gecko"],
                               capture_output=True, text=True, check=True).stdout.strip()) / "xdg-data"


def stored(body: str) -> bool:
    """Whether Gecko's database (the running core's) holds a message with this text."""
    path = app_group() / "gecko/gecko.sqlite"
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return db.execute("SELECT count(*) FROM message WHERE body = ?", (body,)).fetchone()[0] > 0
    finally:
        db.close()


async def push_fetch(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """A push while Gecko is closed: the notification extension fetches, decrypts and stores."""
    omemo = peer.plugin["xep_0384"]
    plain, secret = f"push-plain-{secrets.token_hex(3)}", f"push-omemo-{secrets.token_hex(3)}"
    seen = len(peer.messages)
    # Gecko's first message sets up the session the peer then answers on.
    async with App({"DINO_AUTOPEER": peer_jid, "DINO_AUTOOMEMO": "1", "DINO_AUTOSEND": f"hello-{secrets.token_hex(2)}"}):
        await next_encrypted(peer, app_jid, seen)
    peer.send_message(mto=app_jid, mbody=plain, mtype="chat")
    message = peer.make_message(mto=JID(app_jid), mtype="chat")
    message["body"] = secret
    encrypted, _ = await omemo.encrypt_message(message, {JID(app_jid)})
    encrypted["eme"]["namespace"] = oldmemo.oldmemo.NAMESPACE
    encrypted["eme"]["name"] = peer.plugin["xep_0380"].mechanisms[oldmemo.oldmemo.NAMESPACE]
    encrypted.send()
    await asyncio.sleep(3)

    payload = STATE / "push.apns"
    payload.write_text(json.dumps({"aps": {"alert": {"title": "Gecko", "body": "New message"}, "mutable-content": 1}}))
    subprocess.run(["xcrun", "simctl", "push", DEVICE, BUNDLE, str(payload)], check=True, capture_output=True)
    # Gecko is closed: only the extension can have stored these (its log lags
    # by minutes in the Simulator, so the store is the evidence).
    await until("both messages stored by the notification extension",
                lambda: stored(plain) and stored(secret), timeout=45)

    async with App({"DINO_AUTOPEER": peer_jid}) as app:
        event = await until("the pushed OMEMO message in Gecko",
                            lambda: app.find(type="message", direction="in", body=secret, jid=peer_jid))
        assert event.get("encryption") not in (None, "NONE")
        await asyncio.sleep(3)
        shown = {e.get("item") for e in app.events if e.get("type") == "message" and e.get("body") == plain}
        assert len(shown) == 1, f"the plain message shows as {len(shown)} items"


async def push_register(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """Gecko registers with a push service (the peer here) and sends it its filters."""
    from xml.etree import ElementTree as ET
    seen = len(peer.messages)
    try:
        async with App({"DINO_AUTOPUSH": peer_jid}):
            # Sent only once the server accepted the registration.
            filters = await until("Gecko's push filters at the service", lambda: next(
                (m for m in peer.messages[seen:] if m["from"].bare == app_jid
                 and stanza_child(m, "filters", "urn:gecko:push:filters") is not None), None))
            rules = json.loads(stanza_child(filters, "filters", "urn:gecko:push:filters").text)
            assert rules["token"] == "live-test-token", rules
            assert isinstance(rules["muted"], list) and isinstance(rules["mention_only"], list), rules
            assert filters["body"] == "", "a chat client would show it"
    finally:
        # The registration is the account's: undo it, or the server keeps
        # pushing to the peer.
        me = Peer(app_jid, credentials()["PASSWORD"])
        me.connect()
        await asyncio.wait_for(me.ready.wait(), 30)
        iq = me.make_iq_set()
        iq.append(ET.Element("{urn:xmpp:push:0}disable", {"jid": peer_jid}))
        await iq.send()
        me.disconnect()


async def call_signalling(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """A call's signalling both ways (XEP-0353, then Jingle), the peer as callee; no media."""
    from xml.etree import ElementTree as ET
    jmi, jingle_ns = "urn:xmpp:jingle-message:0", "urn:xmpp:jingle:1"
    seen, seen_iqs = len(peer.messages), len(peer.jingle)
    async with App({"DINO_AUTOCALL": peer_jid}):
        propose = await until("Gecko's call proposal", lambda: next(
            (m for m in peer.messages[seen:] if m["from"].bare == app_jid
             and stanza_child(m, "propose", jmi) is not None), None), timeout=60)
        sid, caller = stanza_child(propose, "propose", jmi).get("id"), propose["from"]
        proceed = peer.make_message(mto=caller, mtype="chat")
        ET.SubElement(proceed.xml, f"{{{jmi}}}proceed", {"id": sid})
        proceed.send()

        def initiate() -> Any:
            for iq in peer.jingle[seen_iqs:]:
                node = iq.xml.find(f"{{{jingle_ns}}}jingle")
                if node.get("sid") == sid and node.get("action") == "session-initiate":
                    return iq
            return None
        offer = await until("Gecko's Jingle offer", initiate, timeout=60)
        assert offer.xml.find(f".//{{urn:xmpp:jingle:apps:rtp:1}}description") is not None, "no RTP description"
        offer.reply().send()

        terminate = peer.make_iq_set(ito=caller)
        node = ET.SubElement(terminate.xml, f"{{{jingle_ns}}}jingle", {"action": "session-terminate", "sid": sid})
        ET.SubElement(ET.SubElement(node, f"{{{jingle_ns}}}reason"), f"{{{jingle_ns}}}success")
        answer = await terminate.send(timeout=20)
        assert answer["type"] == "result", f"Gecko answered the hang-up with {answer['type']}"


async def other_devices(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """What arrived while Gecko was closed, and what another of our devices sent."""
    missed = f"while-closed-{secrets.token_hex(3)}"
    peer.send_message(mto=app_jid, mbody=missed, mtype="chat")
    await asyncio.sleep(2)
    creds = credentials()
    laptop = Peer(app_jid, creds["PASSWORD"])
    laptop.connect()
    await asyncio.wait_for(laptop.ready.wait(), 30)
    try:
        async with App({"DINO_AUTOPEER": peer_jid, "DINO_AUTOOMEMO": "0"}) as app:
            await until("the message sent while Gecko was closed",
                        lambda: app.find(type="message", direction="in", body=missed, jid=peer_jid))
            await until("Gecko online", lambda: app.find(type="connection", state="CONNECTED"))
            # Carbons are switched on a moment after connecting.
            await asyncio.sleep(6)
            elsewhere = f"from-my-laptop-{secrets.token_hex(3)}"
            laptop.send_message(mto=peer_jid, mbody=elsewhere, mtype="chat")
            await until("the other device's message in Gecko, as ours",
                        lambda: app.find(type="message", direction="out", body=elsewhere, jid=peer_jid))
    finally:
        laptop.disconnect()


async def profile(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """Avatars, blocking, and a password change (to the same password)."""
    import base64
    import hashlib
    png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
    avatar_id = hashlib.sha1(png).hexdigest()
    await peer.plugin["xep_0084"].publish_avatar(png)
    await peer.plugin["xep_0084"].publish_avatar_metadata(
        items=[{"id": avatar_id, "type": "image/png", "bytes": len(png)}])

    async with App({"DINO_AUTOPEER": peer_jid}) as app:
        await until("the peer's avatar in Gecko", lambda: next(
            (e for e in app.events if e["type"] == "avatar" and e.get("jid") == peer_jid
             and Path(e.get("path", "")).is_file()
             and hashlib.sha1(Path(e["path"]).read_bytes()).hexdigest() == avatar_id), None))

    async with App({"DINO_AUTOBLOCK": peer_jid, "DINO_AUTOBLOCKLIST": "1"}) as app:
        await until("the peer on Gecko's block list", lambda: any(
            e["type"] == "blocklist" and peer_jid in e.get("list", []) for e in app.events))
    async with App({"DINO_AUTOUNBLOCK": peer_jid, "DINO_AUTOBLOCKLIST": "1"}) as app:
        await until("the peer off Gecko's block list", lambda: any(
            e["type"] == "blocklist" and e.get("supported") and peer_jid not in e.get("list", [])
            for e in app.events[-3:]))

    async with App({"DINO_AUTOCHANGEPASSWORD": credentials()["PASSWORD"]}) as app:
        await until("the password change confirmed", lambda: app.find(type="password_changed"))


async def status(peer: Peer, app_jid: str, peer_jid: str) -> None:
    """Our presence status reaches contacts; needs contact-request first."""
    # Only presence sent after the change counts: the server replays a
    # contact's last presence, status included, to new subscribers.
    count = len(peer.presences)
    async with App({"DINO_AUTOSTATUS": "away:gone fishing"}):
        await until("Gecko's away status at the peer", lambda: any(
            p["from"].bare == app_jid and p["type"] == "away" and p["status"] == "gone fishing"
            for p in peer.presences[count:]))
    count = len(peer.presences)
    async with App({"DINO_AUTOSTATUS": "online:"}):
        await until("Gecko back to plain online at the peer", lambda: any(
            p["from"].bare == app_jid and p["show"] == "" and p["status"] == "" and p["type"] == "available"
            for p in peer.presences[count:]))


async def remove_contact(peer: Peer, app_jid: str, peer_jid: str) -> None:
    async with App({"DINO_AUTOREMOVECONTACT": peer_jid}):
        await until("the peer to lose the subscription", lambda: peer.subscription(app_jid) in ("none", "to"))
        await until("Gecko's unsubscription at the peer", lambda: any(
            p["from"].bare == app_jid and p["type"] in ("unsubscribe", "unsubscribed") for p in peer.presences))


STEPS = {
    "reset": reset,
    "contact-request": contact_request,
    "plain-messages": plain_messages,
    "files": files,
    "message-extras": message_extras,
    "other-devices": other_devices,
    "profile": profile,
    "status": status,
    "omemo-messages": omemo_messages,
    "omemo-files": omemo_files,
    "push-fetch": push_fetch,
    "push-register": push_register,
    "call-signalling": call_signalling,
    "group-chat": group_chat,
    "room-omemo": room_omemo,
    "room-admin": room_admin,
    "remove-contact": remove_contact,
}


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("steps", nargs="*", choices=list(STEPS), help="steps to run (default: all, in order)")
    parser.add_argument("--log", action="store_true",
                        help="keep every launch's console, with the stanza log, in ios/live-test/.state/")
    args = parser.parse_args()
    global DEVICE
    DEVICE = pick_device()
    if args.log:
        App.log = True
        App.common["DINO_LOG_XMPP"] = "all"
        for old in STATE.glob("launch-*.log"):
            old.unlink()
    creds = credentials()
    app_jid, peer_jid = creds["USERNAME"], creds["USERNAME2"]
    STATE.mkdir(exist_ok=True)

    peer = Peer(peer_jid, creds["PASSWORD2"])
    for plugin in ("xep_0030", "xep_0045", "xep_0066", "xep_0084", "xep_0199", "xep_0363", "xep_0380"):
        peer.register_plugin(plugin)
    peer.register_plugin("xep_0384", {"json_file_path": str(STATE / "peer-omemo.json")},
                         module=sys.modules[__name__])
    peer.connect()
    await asyncio.wait_for(peer.ready.wait(), 30)
    services = await peer.plugin["xep_0030"].get_items(jid=peer.boundjid.domain)
    peer.plugin["xep_0045"].muc_service = next(
        (str(item[0]) for item in services["disco_items"]["items"] if str(item[0]).startswith("muc.")), None)

    failed = 0
    for name in args.steps or STEPS:
        started = time.monotonic()
        try:
            await STEPS[name](peer, app_jid, peer_jid)
            print(f"PASS {name} ({time.monotonic() - started:.0f}s)", flush=True)
        except Exception as error:  # noqa: BLE001 - every failure is reported, then the run continues
            failed += 1
            print(f"FAIL {name} ({time.monotonic() - started:.0f}s): {type(error).__name__}: {error}", flush=True)
    peer.disconnect()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
