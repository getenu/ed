import
  ed, basic_tests, threading_tests, network_tests, publish_tests,
  object_tests, utils_tests, validation_tests, error_handling_tests, memory_tests,
  lsn_tests, client_tests, partial_tests, capability_tests, materialize_tests,
  lifetime_tests, ctx_teardown_tests, wire_hardening_tests,
  seq_positional_tests

Ed.bootstrap

basic_tests.run()
threading_tests.run()
network_tests.run()
publish_tests.run()
object_tests.run()
utils_tests.run()
validation_tests.run()
error_handling_tests.run()
memory_tests.run()
lsn_tests.run()
client_tests.run()
partial_tests.run()
capability_tests.run()
materialize_tests.run()
lifetime_tests.run()
ctx_teardown_tests.run()
wire_hardening_tests.run()
seq_positional_tests.run()
