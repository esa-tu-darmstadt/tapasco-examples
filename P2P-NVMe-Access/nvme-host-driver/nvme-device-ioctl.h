/**
 * Copyright (c) 2025-2026 Embedded Systems and Applications Group, TU Darmstadt
 */
#ifndef NVME_HOST_DRIVER_NVME_DEVICE_IOCTL_H
#define NVME_HOST_DRIVER_NVME_DEVICE_IOCTL_H

#include <linux/ioctl.h>

// define u64 for user space application
#ifndef u64
typedef uint64_t u64;
#endif

// ioctl constants
#define NVME_IOCTL_MAGIC 74
#define NVME_IOCTL_MAX   4

// ioctl commands
#define NVME_GET_PCIE_BASE    _IOR(NVME_IOCTL_MAGIC, 0x0, unsigned long)
#define NVME_SETUP_IO_QUEUE   _IOWR(NVME_IOCTL_MAGIC, 0x1, unsigned long)
#define NVME_RELEASE_IO_QUEUE _IOWR(NVME_IOCTL_MAGIC, 0x2, unsigned long)
#define NVME_WRITE            _IOWR(NVME_IOCTL_MAGIC, 0x3, unsigned long)
#define NVME_READ             _IOWR(NVME_IOCTL_MAGIC, 0x4, unsigned long)

enum {
        CREATE_IO_QUEUE_PRESENT,
        CREATE_IO_QUEUE_FAILED,
        CREATE_IO_QUEUE_SUCCESS
};

struct ioctl_setup_io_queue_cmd {
        u64 sq_addr;
        u64 cq_addr;
        u64 status;
};

enum {
        RELEASE_IO_QUEUE_NOT_PRESENT,
        RELEASE_IO_QUEUE_FAILED,
        RELEASE_IO_QUEUE_SUCCESS
};

struct ioctl_release_io_queue_cmd {
        u64 status;
};

struct ioctl_nvme_cmd {
        u64 nvme_addr;
        u64 len;
        void *buf;
        u64 status;
};

#endif //NVME_HOST_DRIVER_NVME_DEVICE_IOCTL_H
