"""Host-only, explicit Zigbee commissioning through the connected Midi session."""
from __future__ import annotations
import base64
import uuid
from fastapi import HTTPException, Request
from google.protobuf import message_factory
from . import aliceapi


def install(app, svc, store):
    @app.post('/_zigbee/{action}')
    async def zigbee(action: str, request: Request):
        if request.client is None or request.client.host not in {'127.0.0.1', '::1'}:
            raise HTTPException(403, 'Host access only')
        types = {'start': 'TStartDiscoveryDirective', 'cancel': 'TCancelDiscoveryDirective',
                 'finish': 'TFinishDiscoveryDirective'}
        names = {'start': 'iot_start_discovery_directive', 'cancel': 'iot_cancel_discovery_directive',
                 'finish': 'iot_finish_discovery_directive'}
        if action not in types:
            raise HTTPException(404)
        records = [d for d in store.known_devices() if d.get('platform') == 'cucumber']
        if len(records) != 1:
            raise HTTPException(409, 'Expected one Midi')
        conns = svc.connections.get(records[0]['id']) or set()
        sess = next((s for s in conns if s.proto), None)
        if sess is None:
            raise HTTPException(409, 'Midi proto connection unavailable')
        try:
            body = await request.json()
        except ValueError:
            raise HTTPException(400, 'JSON body required')
        if not isinstance(body, dict):
            raise HTTPException(400, 'JSON object required')
        server_cls, _ = aliceapi._classes()
        pool = server_cls.DESCRIPTOR.file.pool
        cls = message_factory.GetMessageClass(pool.FindMessageTypeByName(
            'NAlice.TIotDiscoveryCapability.' + types[action]))
        msg = cls()
        msg.Name = names[action]
        if action == 'start':
            msg.SessionId = str(uuid.uuid4())
            msg.Protocols.append(0)  # Zigbee
            msg.TimeoutMs = 120000
            msg.DeviceLimit = 1
            msg.Mode = 1  # INTERACTIVE
            params = msg.ProtocolParameters.add()
            params.Protocol = 0
            params.ZigbeeParameters.DeviceLimit = 1
        elif action == 'cancel':
            try:
                msg.SessionId = str(uuid.UUID(str(body['session_id'])))
            except (KeyError, ValueError):
                raise HTTPException(400, 'Valid session_id required')
        else:
            ids = body.get('accepted_ids', [])
            if not isinstance(ids, list) or len(ids) != 1 or not isinstance(ids[0], str) \
                    or len(ids[0]) > 256:
                raise HTTPException(400, 'Exactly one accepted device required')
            callback_id = body.get('callback_id')
            if type(callback_id) is not int or not 0 <= callback_id < 2 ** 32:  # uint32
                raise HTTPException(400, 'callback_id from the current discovery callback required')
            msg.CallbackId = callback_id
            ep = msg.AcceptedEndpoints.add()
            ep.Id = ids[0]
            ep.Protocol = 1  # NAlice.PROTOCOL_ZIGBEE
        wire = aliceapi.encode_server({'Event': {'Header': {'MessageId': str(uuid.uuid4())},
            'Push': {'Directives': [{'Type': 'client_action', 'Name': names[action],
                'PayloadRaw': base64.b64encode(msg.SerializeToString()).decode()}]}}})
        await sess.send_bytes(wire)
        return {'status': 'sent', 'action': action,
                **({'session_id': msg.SessionId, 'timeout_ms': msg.TimeoutMs} if action == 'start' else {})}
