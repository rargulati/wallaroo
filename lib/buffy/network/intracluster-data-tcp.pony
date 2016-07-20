use "net"
use "collections"
use "buffy/messages"
use "buffy/metrics"
use "sendence/bytes"
use "spike"

class LeaderIntraclusterDataNotifier is TCPListenNotify
  let _env: Env
  let _auth: AmbientAuth
  let _name: String
  var _spike_config: SpikeConfig val
  let _coordinator: Coordinator
  var _host: String = ""
  var _service: String = ""

  new iso create(env: Env, auth: AmbientAuth, name: String,
    coordinator: Coordinator, spike_config: SpikeConfig val) =>
    _env = env
    _auth = auth
    _name = name
    _coordinator = coordinator
    _spike_config = spike_config

  fun ref listening(listen: TCPListener ref) =>
    try
      (_host, _service) = listen.local_address().name()
      _env.out.print(_name + " data: listening on " + _host + ":" + _service)
    else
      _env.out.print(_name + " data: couldn't get local address")
      listen.close()
    end

  fun ref not_listening(listen: TCPListener ref) =>
    _env.out.print(_name + " data: couldn't listen")
    listen.close()

  fun ref connected(listen: TCPListener ref) : TCPConnectionNotify iso^ =>
    _spike_config = SpikeConfig(_spike_config.delay, _spike_config.drop,
      _spike_config.seed + 1)
    SpikeWrapper(IntraclusterDataReceiverConnectNotify(_env, _auth, _name,
      _coordinator), _spike_config)

class WorkerIntraclusterDataNotifier is TCPListenNotify
  let _env: Env
  let _auth: AmbientAuth
  let _name: String
  var _spike_config: SpikeConfig val
  let _leader_host: String
  let _leader_service: String
  let _coordinator: Coordinator
  var _host: String = ""
  var _service: String = ""

  new iso create(env: Env, auth: AmbientAuth, name: String, leader_host: String,
    leader_service: String, coordinator: Coordinator,
    spike_config: SpikeConfig val) =>
    _env = env
    _auth = auth
    _name = name
    _leader_host = leader_host
    _leader_service = leader_service
    _coordinator = coordinator
    _spike_config = spike_config

  fun ref listening(listen: TCPListener ref) =>
    try
      (_host, _service) = listen.local_address().name()
      _env.out.print(_name + " data: listening on " + _host + ":" + _service)

      _coordinator.identify_data_channel(_service)
    else
      _env.out.print(_name + " data: couldn't get local address")
      listen.close()
    end

  fun ref not_listening(listen: TCPListener ref) =>
    _env.out.print(_name + " data: couldn't listen")
    listen.close()

  fun ref connected(listen: TCPListener ref) : TCPConnectionNotify iso^ =>
    _spike_config = SpikeConfig(_spike_config.delay, _spike_config.drop,
      _spike_config.seed + 1)
    SpikeWrapper(IntraclusterDataReceiverConnectNotify(_env, _auth, _name,
      _coordinator), _spike_config)

class IntraclusterDataReceiverConnectNotify is TCPConnectionNotify
  let _env: Env
  let _auth: AmbientAuth
  let _name: String
  var _sender_name: String = ""
  let _coordinator: Coordinator
  var _header: Bool = true
  var _msg_count: U64 = 0

  new iso create(env: Env, auth: AmbientAuth, name: String,
    coordinator: Coordinator) =>
    _env = env
    _auth = auth
    _name = name
    _coordinator = coordinator

  fun ref accepted(conn: TCPConnection ref) =>
    conn.expect(4)
    _coordinator.add_connection(conn)

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso): Bool =>
    if _header then
      try
        let expect = Bytes.to_u32(data(0), data(1), data(2), data(3)).usize()
        conn.expect(expect)
        _header = false
      else
        _env.err.print("Error reading header on data channel")
      end
    else
      let msg = WireMsgDecoder(consume data, _auth)
      match msg
      | let d: DataChannelMsg val =>
        let f = d.forward
        _coordinator.deliver(d.id, f.step_id, f.from_node_name, f.msg_id,
          f.source_ts, f.ingress_ts, f.data)
      | let m: DataSenderReadyMsg val =>
        _sender_name = m.node_name
        _coordinator.connect_receiver(m.node_name)
      | let m: UnknownMsg val =>
        _env.err.print("Unknown data Buffy message type.")
      end

      conn.expect(4)
      _header = true
      _msg_count = _msg_count + 1
      if _msg_count >= 5 then
        _msg_count = 0
        return false
      end
    end
    true

  fun ref closed(conn: TCPConnection ref) =>
    _coordinator.close_receiver(_sender_name)
    _env.out.print("DataReceiverNotify: closed!")

class IntraclusterDataSenderConnectNotify is TCPConnectionNotify
  let _env: Env
  let _auth: AmbientAuth
  let _name: String
  let _target_name: String
  let _coordinator: Coordinator

  new iso create(env: Env, auth: AmbientAuth, name: String, 
    target_name: String, coordinator: Coordinator)
  =>
    _env = env
    _auth = auth
    _name = name
    _target_name = target_name
    _coordinator = coordinator

  fun ref accepted(conn: TCPConnection ref) =>
    _coordinator.add_connection(conn)

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso): Bool =>
    _env.out.print("Data sender channel received data.")
    true

  fun ref closed(conn: TCPConnection ref) =>
    _coordinator.reconnect_data(_target_name)
