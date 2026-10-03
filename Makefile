TARGET := iphone:clang:latest:14.0
ARCHS  = arm64 arm64e
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XhsNoAutoRefresh

XhsNoAutoRefresh_FILES      = Tweak.x
XhsNoAutoRefresh_FRAMEWORKS = UIKit Foundation

# -dead_strip_dylibs：产物不引用 substrate 符号后，链接器会把 libsubstrate 从
# LC_LOAD_DYLIB 里摘掉 —— 这是「零 Logos / 不依赖 CydiaSubstrate」的最后一环。
XhsNoAutoRefresh_CFLAGS     = -fobjc-arc -Wno-unused-variable -Wno-unused-function \
                              -Wno-deprecated-declarations -Wno-unused-const-variable
XhsNoAutoRefresh_LDFLAGS    = -Wl,-dead_strip_dylibs

include $(THEOS_MAKE_PATH)/tweak.mk
