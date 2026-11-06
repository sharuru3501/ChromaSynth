# ChromaSynth bridge firmware (ESP32-S3). Build with ESP-IDF:  idf.py set-target esp32s3 && idf.py build
# See docs/FIRMWARE.md. The portable logic lives in core/ and is tested on the host: make -C test
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(chromasynth_bridge)
