import
  ed, basic_tests, threading_tests, network_tests, publish_tests,
  object_tests, utils_tests, validation_tests, error_handling_tests, memory_tests,
  lsn_tests

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
