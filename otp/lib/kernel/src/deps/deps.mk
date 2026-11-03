../ebin/application.beam: application.erl
../ebin/application_controller.beam: application_controller.erl \
  application_master.hrl ../../kernel/src/../include/logger.hrl
../ebin/application_master.beam: application_master.erl \
  application_master.hrl
../ebin/application_starter.beam: application_starter.erl
../ebin/auth.beam: auth.erl \
  ../../kernel/include/file.hrl
../ebin/code.beam: code.erl \
  ../../kernel/include/logger.hrl \
  ../../kernel/src/../include/eep48.hrl \
  ../../kernel/include/file.hrl
../ebin/code_server.beam: code_server.erl \
  ../../kernel/include/file.hrl \
  ../../stdlib/include/ms_transform.hrl
../ebin/data_publisher.beam: data_publisher.erl
../ebin/disk_log.beam: disk_log.erl disk_log.hrl \
  ../../kernel/include/file.hrl
../ebin/disk_log_1.beam: disk_log_1.erl disk_log.hrl \
  ../../kernel/include/file.hrl
../ebin/disk_log_server.beam: disk_log_server.erl disk_log.hrl \
  ../../kernel/include/file.hrl
../ebin/disk_log_sup.beam: disk_log_sup.erl
../ebin/dist_ac.beam: dist_ac.erl
../ebin/dist_util.beam: dist_util.erl \
  ../../kernel/src/../include/dist_util.hrl \
  ../../kernel/src/../include/dist.hrl
../ebin/erl_boot_server.beam: erl_boot_server.erl inet_boot.hrl
../ebin/erl_compile_server.beam: erl_compile_server.erl
../ebin/erl_ddll.beam: erl_ddll.erl
../ebin/erl_debugger.beam: erl_debugger.erl
../ebin/erl_distribution.beam: erl_distribution.erl \
  ../../kernel/include/logger.hrl
../ebin/erl_erts_errors.beam: erl_erts_errors.erl
../ebin/erl_epmd.beam: erl_epmd.erl \
  ../../kernel/src/../include/dist.hrl inet_int.hrl \
  erl_epmd.hrl ../../kernel/include/inet.hrl
../ebin/erl_kernel_errors.beam: erl_kernel_errors.erl
../ebin/erl_reply.beam: erl_reply.erl
../ebin/erl_signal_handler.beam: erl_signal_handler.erl
../ebin/erpc.beam: erpc.erl
../ebin/erts_debug.beam: erts_debug.erl
../ebin/error_handler.beam: error_handler.erl
../ebin/error_logger.beam: error_logger.erl logger_internal.hrl \
  ../../kernel/include/logger.hrl
../ebin/file.beam: file.erl file_int.hrl \
  ../../kernel/src/../include/file.hrl
../ebin/file_io_server.beam: file_io_server.erl file_int.hrl \
  ../../kernel/src/../include/file.hrl
../ebin/file_server.beam: file_server.erl
../ebin/gen_tcp.beam: gen_tcp.erl inet_int.hrl \
  ../../kernel/src/../include/file.hrl
../ebin/gen_tcp_socket.beam: gen_tcp_socket.erl inet_int.hrl socket_int.hrl
../ebin/gen_udp.beam: gen_udp.erl inet_int.hrl
../ebin/gen_udp_socket.beam: gen_udp_socket.erl inet_int.hrl socket_int.hrl
../ebin/gen_sctp.beam: gen_sctp.erl \
  ../../kernel/src/../include/inet_sctp.hrl
../ebin/global.beam: global.erl \
  ../../stdlib/include/ms_transform.hrl
../ebin/global_group.beam: global_group.erl
../ebin/global_search.beam: global_search.erl
../ebin/group.beam: group.erl \
  ../../kernel/include/logger.hrl
../ebin/group_history.beam: group_history.erl \
  ../../kernel/include/logger.hrl
../ebin/heart.beam: heart.erl
../ebin/inet.beam: inet.erl \
  ../../kernel/src/../include/inet.hrl inet_int.hrl \
  ../../kernel/src/../include/inet_sctp.hrl
../ebin/inet6_tcp.beam: inet6_tcp.erl inet_int.hrl
../ebin/inet6_tcp_dist.beam: inet6_tcp_dist.erl
../ebin/inet6_udp.beam: inet6_udp.erl inet_int.hrl
../ebin/inet6_sctp.beam: inet6_sctp.erl \
  ../../kernel/src/../include/inet_sctp.hrl inet_int.hrl
../ebin/inet_config.beam: inet_config.erl inet_config.hrl \
  ../../kernel/src/../include/inet.hrl
../ebin/inet_db.beam: inet_db.erl \
  ../../kernel/include/file.hrl \
  ../../kernel/src/../include/inet.hrl inet_int.hrl \
  inet_res.hrl inet_dns.hrl inet_config.hrl
../ebin/inet_dns.beam: inet_dns.erl inet_int.hrl inet_dns.hrl \
  inet_dns_record_adts.hrl
../ebin/inet_dns_tsig.beam: inet_dns_tsig.erl inet_dns.hrl
../ebin/inet_epmd_dist.beam: inet_epmd_dist.erl \
  ../../kernel/src/../include/net_address.hrl \
  ../../kernel/src/../include/dist.hrl \
  ../../kernel/src/../include/dist_util.hrl
../ebin/inet_epmd_socket.beam: inet_epmd_socket.erl \
  ../../kernel/src/../include/net_address.hrl \
  ../../kernel/src/../include/dist.hrl \
  ../../kernel/src/../include/dist_util.hrl
../ebin/inet_gethost_native.beam: inet_gethost_native.erl \
  ../../kernel/include/inet.hrl
../ebin/inet_hosts.beam: inet_hosts.erl \
  ../../kernel/src/../include/inet.hrl inet_int.hrl
../ebin/inet_parse.beam: inet_parse.erl \
  ../../kernel/include/file.hrl inet_int.hrl
../ebin/inet_res.beam: inet_res.erl \
  ../../kernel/include/inet.hrl inet_res.hrl \
  inet_dns.hrl inet_int.hrl
../ebin/inet_tcp.beam: inet_tcp.erl inet_int.hrl
../ebin/inet_tcp_dist.beam: inet_tcp_dist.erl \
  ../../kernel/src/../include/net_address.hrl \
  ../../kernel/src/../include/dist.hrl \
  ../../kernel/src/../include/dist_util.hrl
../ebin/inet_udp.beam: inet_udp.erl inet_int.hrl
../ebin/inet_sctp.beam: inet_sctp.erl \
  ../../kernel/src/../include/inet_sctp.hrl inet_int.hrl
../ebin/kernel.beam: kernel.erl
../ebin/kernel_config.beam: kernel_config.erl
../ebin/kernel_refc.beam: kernel_refc.erl
../ebin/local_udp.beam: local_udp.erl inet_int.hrl
../ebin/local_tcp.beam: local_tcp.erl inet_int.hrl
../ebin/logger.beam: logger.erl logger_internal.hrl \
  ../../kernel/include/logger.hrl \
  ../../kernel/src/../include/logger.hrl
../ebin/logger_backend.beam: logger_backend.erl logger_internal.hrl \
  ../../kernel/include/logger.hrl
../ebin/logger_config.beam: logger_config.erl logger_internal.hrl \
  ../../kernel/include/logger.hrl
../ebin/logger_handler.beam: logger_handler.erl
../ebin/logger_handler_watcher.beam: logger_handler_watcher.erl
../ebin/logger_std_h.beam: logger_std_h.erl \
  ../../kernel/src/../include/logger.hrl logger_internal.hrl \
  ../../kernel/include/logger.hrl logger_h_common.hrl \
  ../../kernel/include/file.hrl
../ebin/logger_disk_log_h.beam: logger_disk_log_h.erl \
  ../../kernel/src/../include/logger.hrl logger_internal.hrl \
  ../../kernel/include/logger.hrl logger_h_common.hrl
../ebin/logger_h_common.beam: logger_h_common.erl logger_h_common.hrl \
  logger_internal.hrl ../../kernel/include/logger.hrl
../ebin/logger_filters.beam: logger_filters.erl logger_internal.hrl \
  ../../kernel/include/logger.hrl
../ebin/logger_formatter.beam: logger_formatter.erl logger_internal.hrl \
  ../../kernel/include/logger.hrl
../ebin/logger_olp.beam: logger_olp.erl logger_olp.hrl logger_internal.hrl \
  ../../kernel/include/logger.hrl
../ebin/logger_proxy.beam: logger_proxy.erl logger_internal.hrl \
  ../../kernel/include/logger.hrl
../ebin/logger_server.beam: logger_server.erl logger_internal.hrl \
  ../../kernel/include/logger.hrl
../ebin/logger_simple_h.beam: logger_simple_h.erl
../ebin/logger_sup.beam: logger_sup.erl
../ebin/net.beam: net.erl
../ebin/net_adm.beam: net_adm.erl
../ebin/net_kernel.beam: net_kernel.erl \
  ../../kernel/src/../include/net_address.hrl \
  ../../kernel/include/logger.hrl
../ebin/os.beam: os.erl ../../kernel/src/../include/file.hrl
../ebin/pg.beam: pg.erl
../ebin/pg2.beam: pg2.erl
../ebin/ram_file.beam: ram_file.erl \
  ../../kernel/src/../include/file.hrl
../ebin/rpc.beam: rpc.erl
../ebin/seq_trace.beam: seq_trace.erl
../ebin/socket.beam: socket.erl file_int.hrl \
  ../../kernel/src/../include/file.hrl
../ebin/standard_error.beam: standard_error.erl \
  ../../kernel/include/logger.hrl
../ebin/trace.beam: trace.erl
../ebin/user_drv.beam: user_drv.erl \
  ../../kernel/include/logger.hrl
../ebin/user_sup.beam: user_sup.erl
../ebin/prim_tty.beam: prim_tty.erl
../ebin/prim_tty_sighandler.beam: prim_tty_sighandler.erl
../ebin/raw_file_io.beam: raw_file_io.erl
../ebin/raw_file_io_compressed.beam: raw_file_io_compressed.erl file_int.hrl \
  ../../kernel/src/../include/file.hrl
../ebin/raw_file_io_inflate.beam: raw_file_io_inflate.erl file_int.hrl \
  ../../kernel/src/../include/file.hrl
../ebin/raw_file_io_deflate.beam: raw_file_io_deflate.erl file_int.hrl \
  ../../kernel/src/../include/file.hrl
../ebin/raw_file_io_delayed.beam: raw_file_io_delayed.erl file_int.hrl \
  ../../kernel/src/../include/file.hrl
../ebin/raw_file_io_list.beam: raw_file_io_list.erl file_int.hrl \
  ../../kernel/src/../include/file.hrl
../ebin/wrap_log_reader.beam: wrap_log_reader.erl disk_log.hrl \
  ../../kernel/include/file.hrl
