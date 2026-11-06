idf_component_register(SRCS "main.c" "usb_midi.c" "link.c" "../core/bridge_core.c"
                       INCLUDE_DIRS "." "../core"
                       PRIV_REQUIRES esp_timer driver esp_rom)
