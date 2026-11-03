../ebin/array.beam: array.erl
../ebin/argparse.beam: argparse.erl
../ebin/base64.beam: base64.erl
../ebin/beam_lib.beam: beam_lib.erl \
  ../../kernel/include/eep48.hrl
../ebin/binary.beam: binary.erl
../ebin/c.beam: c.erl ../../kernel/include/eep48.hrl
../ebin/calendar.beam: calendar.erl
../ebin/dets.beam: dets.erl \
  ../../kernel/include/logger.hrl dets.hrl
../ebin/dets_server.beam: dets_server.erl dets.hrl
../ebin/dets_sup.beam: dets_sup.erl
../ebin/dets_utils.beam: dets_utils.erl \
  ../../kernel/include/logger.hrl dets.hrl
../ebin/dets_v9.beam: dets_v9.erl dets.hrl
../ebin/dict.beam: dict.erl
../ebin/graph.beam: graph.erl
../ebin/digraph.beam: digraph.erl
../ebin/digraph_utils.beam: digraph_utils.erl
../ebin/edlin.beam: edlin.erl
../ebin/edlin_key.beam: edlin_key.erl
../ebin/edlin_context.beam: edlin_context.erl
../ebin/edlin_expand.beam: edlin_expand.erl \
  ../../kernel/include/eep48.hrl
../ebin/edlin_type_suggestion.beam: edlin_type_suggestion.erl \
  ../../kernel/include/eep48.hrl
../ebin/epp.beam: epp.erl \
  ../../kernel/include/file.hrl
../ebin/erl_abstract_code.beam: erl_abstract_code.erl
../ebin/erl_anno.beam: erl_anno.erl
../ebin/erl_bits.beam: erl_bits.erl \
  ../../stdlib/include/erl_bits.hrl
../ebin/erl_compile.beam: erl_compile.erl \
  ../../stdlib/src/../include/erl_compile.hrl \
  ../../stdlib/src/../../kernel/include/file.hrl
../ebin/erl_error.beam: erl_error.erl
../ebin/erl_eval.beam: erl_eval.erl
../ebin/erl_expand_records.beam: erl_expand_records.erl
../ebin/erl_features.beam: erl_features.erl
../ebin/erl_internal.beam: erl_internal.erl
../ebin/erl_lint.beam: erl_lint.erl \
  ../../stdlib/include/erl_bits.hrl
../ebin/erl_parse.beam: erl_parse.erl erl_parse.yrl \
  ../../parsetools/include/yeccpre.hrl
../ebin/erl_posix_msg.beam: erl_posix_msg.erl
../ebin/erl_pp.beam: erl_pp.erl
../ebin/erl_scan.beam: erl_scan.erl
../ebin/erl_stdlib_errors.beam: erl_stdlib_errors.erl
../ebin/erl_tar.beam: erl_tar.erl \
  ../../kernel/include/file.hrl erl_tar.hrl
../ebin/error_logger_file_h.beam: error_logger_file_h.erl
../ebin/error_logger_tty_h.beam: error_logger_tty_h.erl
../ebin/escript.beam: escript.erl
../ebin/ets.beam: ets.erl
../ebin/eval_bits.beam: eval_bits.erl
../ebin/file_sorter.beam: file_sorter.erl \
  ../../kernel/include/file.hrl
../ebin/filelib.beam: filelib.erl \
  ../../kernel/include/file.hrl
../ebin/filename.beam: filename.erl \
  ../../kernel/include/file.hrl
../ebin/gb_trees.beam: gb_trees.erl
../ebin/gb_sets.beam: gb_sets.erl
../ebin/gen.beam: gen.erl \
  ../../stdlib/src/../../kernel/include/logger.hrl
../ebin/gen_event.beam: gen_event.erl \
  ../../stdlib/src/../../kernel/include/logger.hrl
../ebin/gen_fsm.beam: gen_fsm.erl \
  ../../stdlib/src/../../kernel/include/logger.hrl
../ebin/gen_server.beam: gen_server.erl \
  ../../stdlib/src/../../kernel/include/logger.hrl
../ebin/gen_statem.beam: gen_statem.erl \
  ../../stdlib/src/../../kernel/include/logger.hrl
../ebin/io.beam: io.erl
../ebin/io_ansi.beam: io_ansi.erl
../ebin/io_lib.beam: io_lib.erl
../ebin/io_lib_format.beam: io_lib_format.erl
../ebin/io_lib_fread.beam: io_lib_fread.erl
../ebin/io_lib_pretty.beam: io_lib_pretty.erl
../ebin/json.beam: json.erl json.hrl swar_ascii.hrl
../ebin/lists.beam: lists.erl
../ebin/log_mf_h.beam: log_mf_h.erl
../ebin/man_docs.beam: man_docs.erl \
  ../../kernel/include/eep48.hrl
../ebin/maps.beam: maps.erl
../ebin/math.beam: math.erl
../ebin/ms_transform.beam: ms_transform.erl ../doc/src/ms_transform.md
../ebin/otp_internal.beam: otp_internal.erl otp_internal.hrl
../ebin/orddict.beam: orddict.erl
../ebin/ordsets.beam: ordsets.erl
../ebin/re.beam: re.erl ../doc/src/re.md
../ebin/records.beam: records.erl
../ebin/peer.beam: peer.erl ../doc/src/peer.md
../ebin/pool.beam: pool.erl
../ebin/proc_lib.beam: proc_lib.erl \
  ../../stdlib/src/../../kernel/include/logger.hrl
../ebin/proplists.beam: proplists.erl
../ebin/qlc.beam: qlc.erl ../doc/src/qlc.md
../ebin/qlc_pt.beam: qlc_pt.erl \
  ../../stdlib/include/ms_transform.hrl
../ebin/queue.beam: queue.erl
../ebin/rand.beam: rand.erl
../ebin/random.beam: random.erl
../ebin/sets.beam: sets.erl
../ebin/shell.beam: shell.erl ../doc/src/shell.md \
  ../../kernel/include/file.hrl
../ebin/shell_default.beam: shell_default.erl
../ebin/shell_docs.beam: shell_docs.erl \
  ../../kernel/include/eep48.hrl
../ebin/shell_docs_markdown.beam: shell_docs_markdown.erl
../ebin/slave.beam: slave.erl
../ebin/sofs.beam: sofs.erl ../doc/src/sofs.md
../ebin/string.beam: string.erl swar_ascii.hrl
../ebin/supervisor.beam: supervisor.erl \
  ../../stdlib/src/../../kernel/include/logger.hrl
../ebin/supervisor_bridge.beam: supervisor_bridge.erl \
  ../../stdlib/src/../../kernel/include/logger.hrl
../ebin/sys.beam: sys.erl
../ebin/timer.beam: timer.erl
../ebin/unicode.beam: unicode.erl
../ebin/unicode_util.beam: unicode_util.erl
../ebin/uri_string.beam: uri_string.erl
../ebin/win32reg.beam: win32reg.erl
../ebin/zip.beam: zip.erl \
  ../../stdlib/src/../../kernel/include/file.hrl \
  ../../stdlib/src/../include/zip.hrl
../ebin/zstd.beam: zstd.erl
