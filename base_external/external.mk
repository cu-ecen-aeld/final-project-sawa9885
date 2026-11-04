# Include the makefiles of this tree's packages (sx1302-hal, basicstation and gwmon arrive in later issues).
include $(sort $(wildcard $(BR2_EXTERNAL_PROJECT_BASE_PATH)/package/*/*.mk))
