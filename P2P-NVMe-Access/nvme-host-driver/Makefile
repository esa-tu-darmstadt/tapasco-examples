TARGET_MODULE := nvme-host-driver
BUILDSYSTEM_DIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)
obj-m := $(TARGET_MODULE).o
$(TARGET_MODULE)-objs := nvme-device.o

all:
	$(MAKE) KCPPFLAGS+="$(CPPFLAGS)" -C $(BUILDSYSTEM_DIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(BUILDSYSTEM_DIR) M=$(PWD) clean

load:
	insmod ./$(TARGET_MODULE).ko
	chmod a+rw /dev/nvme-host-driver

unload:
	rmmod ./$(TARGET_MODULE).ko

reload:
	rmmod ./$(TARGET_MODULE).ko
	insmod ./$(TARGET_MODULE).ko
	chmod a+rw /dev/nvme-host-driver

.PHONY: clean load unload reload
