use "net"
use "collections"
use "buffy/messages"
use "sendence/bytes"
use "sendence/tcp"

actor TopologyManager
  let _env: Env
  let _step_manager: StepManager
  let _name: String
  let _worker_count: USize
  let _workers: Map[String, TCPConnection tag] = Map[String, TCPConnection tag]
  let _worker_addrs: Map[String, (String, String)] = Map[String, (String, String)]
  // Keep track of how many workers identified themselves
  var _hellos: USize = 0
  // Keep track of how many workers acknowledged they're running their
  // part of the topology
  var _acks: USize = 0
  var _phone_home_host: String = ""
  var _phone_home_service: String = ""

  new create(env: Env, name: String, worker_count: USize, phone_home: String,
    step_manager: StepManager) =>
    _env = env
    _step_manager = step_manager
    _name = name
    _worker_count = worker_count
    if phone_home != "" then
      let ph_addr = phone_home.split(":")
      try
        _phone_home_host = ph_addr(0)
        _phone_home_service = ph_addr(1)
      end
    end

    if _worker_count == 0 then _complete_initialization() end

  be assign_name(conn: TCPConnection tag, node_name: String,
    host: String, service: String) =>
    _workers(node_name) = conn
    _worker_addrs(node_name) = (host, service)
    _env.out.print("Identified worker " + node_name)
    _hellos = _hellos + 1
    if _hellos == _worker_count then
      _env.out.print("_--- All workers accounted for! ---_")
      initialize_topology()
    end

  be update_connection(conn: TCPConnection tag, node_name: String) =>
    _workers(node_name) = conn

  be ack_initialized() =>
    _acks = _acks + 1
    if _acks == _worker_count then
      _complete_initialization()
    end

  fun ref initialize_topology() =>
    try
      let keys = _workers.keys()
      let remote_node_name1: String = keys.next()
      let remote_node_name2: String = keys.next()
      let node2_addr = _worker_addrs(remote_node_name2)

      let double_step_id: I32 = 1
      let halve_step_id: I32 = 2
      let halve_to_print_proxy_id: I32 = 3
      let print_step_id: I32 = 4


      let halve_create_msg =
        WireMsgEncoder.spin_up(halve_step_id, ComputationTypes.halve())
      let halve_to_print_proxy_create_msg =
        WireMsgEncoder.spin_up_proxy(halve_to_print_proxy_id,
          print_step_id, remote_node_name2, node2_addr._1, node2_addr._2)
      let print_create_msg =
        WireMsgEncoder.spin_up(print_step_id, ComputationTypes.print())
      let connect_msg =
        WireMsgEncoder.connect_steps(halve_step_id, halve_to_print_proxy_id)
      let finished_msg =
        WireMsgEncoder.initialization_msgs_finished()

      //Leader node (i.e. this one)
      _step_manager.add_step(double_step_id, ComputationTypes.double())

      //First worker node
      var conn1 = _workers(remote_node_name1)
      conn1.write(halve_create_msg)
      conn1.write(halve_to_print_proxy_create_msg)
      conn1.write(connect_msg)
      conn1.write(finished_msg)

      //Second worker node
      var conn2 = _workers(remote_node_name2)
      conn2.write(print_create_msg)
      conn2.write(finished_msg)

      let halve_proxy_id: I32 = 5
      _step_manager.add_proxy(halve_proxy_id, halve_step_id, conn1)
      _step_manager.connect_steps(1, 5)

      for i in Range(0, 100) do
        let next_msg = Message[I32](i.i32(), i.i32())
        _step_manager(1, next_msg)
      end
    else
      _env.out.print("Buffy Leader: Failed to initialize topology")
    end

  fun _complete_initialization() =>
    _env.out.print("_--- Topology successfully initialized ---_")
    if _has_phone_home() then
      try
        let env = _env
        let auth = env.root as AmbientAuth
        let name = _name
        let notifier: TCPConnectionNotify iso =
          recover HomeConnectNotify(env, name) end
        let conn: TCPConnection =
          TCPConnection(auth, consume notifier, _phone_home_host, _phone_home_service)

        let message = WireMsgEncoder.ready(_name)
        conn.write(message)
      else
        _env.out.print("Couldn't get ambient authority when completing "
          + "initialization")
      end
    end

  fun _has_phone_home(): Bool =>
    (_phone_home_host != "") and (_phone_home_service != "")

class LeaderNotifier is TCPListenNotify
  let _env: Env
  let _auth: AmbientAuth
  let _name: String
  let _topology_manager: TopologyManager
  let _step_manager: StepManager
  var _host: String = ""
  var _service: String = ""

  new iso create(env: Env, auth: AmbientAuth, name: String, host: String,
    service: String, worker_count: USize, phone_home: String) =>
    _env = env
    _auth = auth
    _name = name
    _host = host
    _service = service
    _step_manager = StepManager(env)
    _topology_manager = TopologyManager(env, name, worker_count, phone_home,
      _step_manager)

  fun ref listening(listen: TCPListener ref) =>
    try
      (_host, _service) = listen.local_address().name()
      _env.out.print(_name + ": listening on " + _host + ":" + _service)
    else
      _env.out.print(_name + ": couldn't get local address")
      listen.close()
    end

  fun ref not_listening(listen: TCPListener ref) =>
    _env.out.print(_name + ": couldn't listen")
    listen.close()

  fun ref connected(listen: TCPListener ref) : TCPConnectionNotify iso^ =>
    LeaderConnectNotify(_env, _auth, _name, _topology_manager, _step_manager)

class LeaderConnectNotify is TCPConnectionNotify
  let _env: Env
  let _auth: AmbientAuth
  let _name: String
  let _topology_manager: TopologyManager
  let _step_manager: StepManager
  let _framer: Framer = Framer
  let _nodes: Map[String, TCPConnection tag] = Map[String, TCPConnection tag]
  var _buffer: Array[U8] = Array[U8]
  // How many bytes are left to process for current message
  var _left: U32 = 0
  // For building up the two bytes of a U16 message length
  var _len_bytes: Array[U8] = Array[U8]
  var _data_index: USize = 0

  new iso create(env: Env, auth: AmbientAuth, name: String, t_manager: TopologyManager,
    s_manager: StepManager) =>
    _env = env
    _auth = auth
    _name = name
    _topology_manager = t_manager
    _step_manager = s_manager

  fun ref accepted(conn: TCPConnection ref) =>
    _env.out.print(_name + ": connection accepted")

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso) =>
    for chunked in _framer.chunk(consume data).values() do
      try
        let msg = WireMsgDecoder(consume chunked)
        match msg
        | let m: IdentifyMsg val =>
          _nodes(m.node_name) = conn
          _topology_manager.assign_name(conn, m.node_name, m.host, m.service)
        | let m: AckInitializedMsg val =>
          _topology_manager.ack_initialized()
        | let m: ReconnectMsg val =>
          _topology_manager.update_connection(conn, m.node_name)
        | let m: SpinUpMsg val =>
          _step_manager.add_step(m.step_id, m.computation_type_id)
        | let m: SpinUpProxyMsg val =>
          _spin_up_proxy(m)
        | let m: ForwardMsg val =>
          _step_manager(m.step_id, m.msg)
        | let m: ConnectStepsMsg val =>
          _step_manager.connect_steps(m.in_step_id, m.out_step_id)
        else
          _env.err.print("Error decoding incoming message.")
        end
      else
        _env.err.print("Error decoding incoming message.")
      end
    end

  fun ref _spin_up_proxy(msg: SpinUpProxyMsg val) =>
    try
      let target_conn = _nodes(msg.target_node_name)
      _step_manager.add_proxy(msg.proxy_id, msg.step_id, target_conn)
    else
      let notifier: TCPConnectionNotify iso =
        LeaderConnectNotify(_env, _auth, _name, _topology_manager, _step_manager)
      let target_conn =
        TCPConnection(_auth, consume notifier, msg.target_host,
          msg.target_service)
      _step_manager.add_proxy(msg.proxy_id, msg.step_id, target_conn)
      _nodes(msg.target_node_name) = target_conn
    end

  fun ref closed(conn: TCPConnection ref) =>
    _env.out.print(_name + ": server closed")

class HomeConnectNotify is TCPConnectionNotify
  let _env: Env
  let _name: String

  new iso create(env: Env, name: String) =>
    _env = env
    _name = name

  fun ref accepted(conn: TCPConnection ref) =>
    _env.out.print(_name + ": phone home connection accepted")

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso) =>
    _env.out.print(_name + ": received from phone home")

  fun ref closed(conn: TCPConnection ref) =>
    _env.out.print(_name + ": server closed")