idf_component_register(
  SRCS bits.c float.c wputils.c metadata.c unpack.c words.c
  INCLUDE_DIRS .
  LDFRAGMENTS wavpack.lf
)
