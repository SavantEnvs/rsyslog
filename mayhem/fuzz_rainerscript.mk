# Adds the fuzz_rainerscript program to the automake-generated tools/Makefile without touching upstream's
# Makefile.am: the same objects and link line as fuzz_rsyslog_message, with mayhem/fuzz_rainerscript.c as main
# (which includes tools/rsyslogd.c itself, so rsyslogd.o is left out of the link).
# Use:  make -C tools -f Makefile -f $SRC/mayhem/fuzz_rainerscript.mk MAYHEM_SRC=$SRC fuzz_rainerscript

fuzz_rainerscript_OBJECTS = \
	$(filter-out fuzz_rsyslog_message-fuzz_rsyslog_message.$(OBJEXT) fuzz_rsyslog_message-rsyslogd.$(OBJEXT),$(fuzz_rsyslog_message_OBJECTS)) \
	fuzz_rainerscript.$(OBJEXT)

fuzz_rainerscript.$(OBJEXT): $(MAYHEM_SRC)/mayhem/fuzz_rainerscript.c
	$(CC) $(DEFS) $(DEFAULT_INCLUDES) $(INCLUDES) $(fuzz_rsyslog_message_CPPFLAGS) $(CPPFLAGS) $(AM_CFLAGS) $(CFLAGS) -c -o $@ $<

fuzz_rainerscript$(EXEEXT): $(fuzz_rainerscript_OBJECTS) $(fuzz_rsyslog_message_DEPENDENCIES) $(EXTRA_fuzz_rsyslog_message_DEPENDENCIES)
	@rm -f fuzz_rainerscript$(EXEEXT)
	$(fuzz_rsyslog_message_LINK) $(fuzz_rainerscript_OBJECTS) $(fuzz_rsyslog_message_LDADD) $(LIBS)
