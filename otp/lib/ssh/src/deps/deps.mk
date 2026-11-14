../ebin/ssh.beam: ssh.erl ssh.hrl ssh_connect.hrl \
  ../../public_key/include/public_key.hrl \
  ../../kernel/include/file.hrl \
  ../../kernel/include/inet.hrl
../ebin/ssh_acceptor.beam: ssh_acceptor.erl ssh.hrl
../ebin/ssh_acceptor_sup.beam: ssh_acceptor_sup.erl ssh.hrl
../ebin/ssh_agent.beam: ssh_agent.erl ssh.hrl ssh_agent.hrl
../ebin/ssh_app.beam: ssh_app.erl
../ebin/ssh_auth.beam: ssh_auth.erl \
  ../../public_key/include/public_key.hrl ssh.hrl \
  ssh_auth.hrl ssh_agent.hrl ssh_transport.hrl
../ebin/ssh_bits.beam: ssh_bits.erl ssh.hrl
../ebin/ssh_channel_sup.beam: ssh_channel_sup.erl
../ebin/ssh_cli.beam: ssh_cli.erl ssh.hrl ssh_connect.hrl
../ebin/ssh_connection.beam: ssh_connection.erl \
  ../../kernel/include/logger.hrl ssh.hrl \
  ssh_connect.hrl ssh_transport.hrl
../ebin/ssh_connection_handler.beam: ssh_connection_handler.erl ssh.hrl \
  ssh_transport.hrl ssh_auth.hrl ssh_connect.hrl ssh_fsm.hrl
../ebin/ssh_file.beam: ssh_file.erl \
  ../../public_key/include/public_key.hrl \
  ../../kernel/include/file.hrl ssh.hrl
../ebin/ssh_fsm_kexinit.beam: ssh_fsm_kexinit.erl ssh.hrl ssh_transport.hrl \
  ssh_auth.hrl ssh_connect.hrl ssh_fsm.hrl
../ebin/ssh_fsm_userauth_client.beam: ssh_fsm_userauth_client.erl ssh.hrl \
  ssh_transport.hrl ssh_auth.hrl ssh_connect.hrl ssh_fsm.hrl
../ebin/ssh_fsm_userauth_server.beam: ssh_fsm_userauth_server.erl ssh.hrl \
  ssh_transport.hrl ssh_auth.hrl ssh_connect.hrl ssh_fsm.hrl
../ebin/ssh_info.beam: ssh_info.erl ssh.hrl ssh_connect.hrl
../ebin/ssh_io.beam: ssh_io.erl ssh.hrl
../ebin/ssh_lib.beam: ssh_lib.erl ssh.hrl
../ebin/ssh_lsocket.beam: ssh_lsocket.erl ssh.hrl
../ebin/ssh_lsocket_sup.beam: ssh_lsocket_sup.erl
../ebin/ssh_message.beam: ssh_message.erl \
  ../../public_key/include/public_key.hrl \
  ../../kernel/include/logger.hrl ssh.hrl \
  ssh_connect.hrl ssh_auth.hrl ssh_transport.hrl
../ebin/ssh_no_io.beam: ssh_no_io.erl ssh_transport.hrl
../ebin/ssh_options.beam: ssh_options.erl ssh.hrl \
  ../../kernel/include/file.hrl
../ebin/ssh_sftp.beam: ssh_sftp.erl \
  ../../kernel/include/file.hrl ssh.hrl ssh_xfer.hrl
../ebin/ssh_sftpd.beam: ssh_sftpd.erl \
  ../../kernel/include/file.hrl \
  ../../kernel/include/logger.hrl ssh.hrl \
  ssh_xfer.hrl ssh_connect.hrl
../ebin/ssh_sftpd_file.beam: ssh_sftpd_file.erl
../ebin/ssh_shell.beam: ssh_shell.erl ssh.hrl ssh_connect.hrl
../ebin/ssh_connection_sup.beam: ssh_connection_sup.erl ssh.hrl
../ebin/ssh_system_sup.beam: ssh_system_sup.erl ssh.hrl
../ebin/ssh_tcpip_forward_srv.beam: ssh_tcpip_forward_srv.erl
../ebin/ssh_tcpip_forward_client.beam: ssh_tcpip_forward_client.erl
../ebin/ssh_tcpip_forward_acceptor_sup.beam: \
  ssh_tcpip_forward_acceptor_sup.erl ssh.hrl
../ebin/ssh_tcpip_forward_acceptor.beam: ssh_tcpip_forward_acceptor.erl \
  ssh.hrl
../ebin/ssh_transport.beam: ssh_transport.erl \
  ../../public_key/include/public_key.hrl \
  ../../kernel/include/inet.hrl ssh_transport.hrl \
  ssh.hrl
../ebin/ssh_xfer.beam: ssh_xfer.erl ssh.hrl ssh_xfer.hrl
../ebin/ssh_dbg.beam: ssh_dbg.erl ssh.hrl ssh_transport.hrl ssh_connect.hrl \
  ssh_auth.hrl
../ebin/ssh_client_key_api.beam: ssh_client_key_api.erl \
  ../../public_key/include/public_key.hrl ssh.hrl
../ebin/ssh_daemon_channel.beam: ssh_daemon_channel.erl
../ebin/ssh_server_channel.beam: ssh_server_channel.erl
../ebin/ssh_server_key_api.beam: ssh_server_key_api.erl \
  ../../public_key/include/public_key.hrl ssh.hrl
../ebin/ssh_sftpd_file_api.beam: ssh_sftpd_file_api.erl
../ebin/ssh_channel.beam: ssh_channel.erl ssh.hrl ssh_connect.hrl
../ebin/ssh_client_channel.beam: ssh_client_channel.erl ssh.hrl \
  ssh_connect.hrl
