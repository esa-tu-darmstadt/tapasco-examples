/**
 * Copyright notice:
 * struct definitions of NVMe commands taken from unvme driver
 * published under BSD-3 license by
 *
 * Copyright (c) 2015-2016, Micron Technology, Inc.
 *
 * Other parts:
 * Copyright (c) 2025-2026 Embedded Systems and Applications Group, TU Darmstadt
 */

#include <linux/init.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/delay.h>
#include <linux/version.h>

#include "nvme-device-ioctl.h"

#define DEVICE_NAME "nvme-host-driver"
#define CLASS_NAME "nvme-host-class"

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Torben Kalkhof");

static int major_num = 0;
static struct class *nvme_class = NULL;

// queue IDs
enum {
        FPGA_QUEUE_ID = 1,
        HOST_QUEUE_ID = 2,
};

/// NVMe command op code
enum {
        NVME_CMD_FLUSH          = 0x0,      ///< flush
        NVME_CMD_WRITE          = 0x1,      ///< write
        NVME_CMD_READ           = 0x2,      ///< read
        NVME_CMD_WRITE_UNCOR    = 0x4,      ///< write uncorrectable
        NVME_CMD_COMPARE        = 0x5,      ///< compare
        NVME_CMD_DS_MGMT        = 0x9,      ///< dataset management
};

/// NVMe admin command op code
enum {
        NVME_ACMD_DELETE_SQ     = 0x0,      ///< delete io submission queue
        NVME_ACMD_CREATE_SQ     = 0x1,      ///< create io submission queue
        NVME_ACMD_GET_LOG_PAGE  = 0x2,      ///< get log page
        NVME_ACMD_DELETE_CQ     = 0x4,      ///< delete io completion queue
        NVME_ACMD_CREATE_CQ     = 0x5,      ///< create io completion queue
        NVME_ACMD_IDENTIFY      = 0x6,      ///< identify
        NVME_ACMD_ABORT         = 0x8,      ///< abort
        NVME_ACMD_SET_FEATURES  = 0x9,      ///< set features
        NVME_ACMD_GET_FEATURES  = 0xA,      ///< get features
        NVME_ACMD_ASYNC_EVENT   = 0xC,      ///< asynchronous event
        NVME_ACMD_FW_ACTIVATE   = 0x10,     ///< firmware activate
        NVME_ACMD_FW_DOWNLOAD   = 0x11,     ///< firmware image download
};

/// Version
union nvme_version {
        u32                 val;            ///< whole value
        struct {
                u8              rsvd;           ///< reserved
                u8              mnr;            ///< minor version number
                u16             mjr;            ///< major version number
        };
};

/// Admin queue attributes
union nvme_adminq_attr {
        u32                 val;            ///< whole value
        struct {
                u16             asqs;           ///< admin submission queue size
                u16             acqs;           ///< admin completion queue size
        };
};

/// Controller capabilities
union nvme_controller_cap {
        u64                 val;            ///< whole value
        struct {
                u16             mqes;           ///< max queue entries supported
                u8              cqr     : 1;    ///< contiguous queues required
                u8              ams     : 2;    ///< arbitration mechanism supported
                u8              rsvd    : 5;    ///< reserved
                u8              to;             ///< timeout

                u32             dstrd   : 4;    ///< doorbell stride
                u32             nssrs   : 1;    ///< NVM subsystem reset supported
                u32             css     : 8;    ///< command set supported
                u32             bps     : 1;    ///< boot partition support
                u32             cps     : 2;    ///< controller power scope
                u32             mpsmin  : 4;    ///< memory page size minimum
                u32             mpsmax  : 4;    ///< memory page size maximum
                u32             pmrs    : 1;    ///< persistent memory region supported
                u32             cmbs    : 1;    ///< controller memory buffer supported
                u32             nsss    : 1;    ///< NVM subsystem shutdown supported
                u32             crms    : 2;    ///< controller ready modes supported
                u32             rsvd3   : 3;    ///< reserved
        };
};

/// Controller configuration register
union nvme_controller_config {
        u32                 val;            ///< whole value
        struct {
                u32             en      : 1;    ///< enable
                u32             rsvd    : 3;    ///< reserved
                u32             css     : 3;    ///< I/O command set selected
                u32             mps     : 4;    ///< memory page size
                u32             ams     : 3;    ///< arbitration mechanism selected
                u32             shn     : 2;    ///< shutdown notification
                u32             iosqes  : 4;    ///< I/O submission queue entry size
                u32             iocqes  : 4;    ///< I/O completion queue entry size
                u32             crime   : 1;    ///< controller ready independent of media enable
                u32             rsvd2   : 7;    ///< reserved
        };
};

/// Controller status register
union nvme_controller_status {
        u32                 val;            ///< whole value
        struct {
                u32             rdy     : 1;    ///< ready
                u32             cfs     : 1;    ///< controller fatal status
                u32             shst    : 2;    ///< shutdown status
                u32             rsvd    : 28;   ///< reserved
        };
};

struct nvme_controller_reg {
        union nvme_controller_cap    cap;        ///< controller capabilities
        union nvme_version           vs;         ///< version
        u32                          intms;      ///< interrupt mask set
        u32                          intmc;      ///< interrupt mask clear
        union nvme_controller_config cc;        ///< controller configuration
        u32                          rsvd;       ///< reserved
        union nvme_controller_status csts;      ///< controller status
        u32                          nssr;       ///< NVM subsystem reset
        union nvme_adminq_attr       aqa;        ///< admin queue attributes
        u64                          asq;        ///< admin submission queue base address
        u64                          acq;        ///< admin completion queue base address
        u32                          rcss[1010]; ///< reserved and command set specific
        u32                          sq0tdbl[1024]; ///< sq0 tail doorbell at 0x1000
} __packed;

/// Common command header (cdw 0-9)
struct nvme_command_common {
        u8                      opc;        ///< opcode
        u8                      fuse : 2;   ///< fuse
        u8                      rsvd : 6;   ///< reserved
        u16                     cid;        ///< command id
        u32                     nsid;       ///< namespace id
        u32                     cdw2_3[2];  ///< reserved (cdw 2-3)
        u64                     mptr;       ///< metadata pointer
        u64                     prp1;       ///< PRP entry 1
        u64                     prp2;       ///< PRP entry 2
};

/// NVMe command:  Read & Write
struct nvme_command_rw {
        struct nvme_command_common common;     ///< common cdw 0
        u64                        slba;       ///< starting LBA (cdw 10)
        u16                        nlb;        ///< number of logical blocks
        u16                        rsvd12 : 10; ///< reserved (in cdw 12)
        u16                        prinfo : 4; ///< protection information field
        u16                        fua : 1;    ///< force unit access
        u16                        lr  : 1;    ///< limited retry
        u8                         dsm;        ///< dataset management
        u8                         rsvd13[3];  ///< reserved (in cdw 13)
        u32                        eilbrt;     ///< exp initial block reference tag
        u16                        elbat;      ///< exp logical block app tag
        u16                        elbatm;     ///< exp logical block app tag mask
};

/// Admin command:  Delete I/O Submission & Completion Queue
struct nvme_acmd_delete_ioq {
        struct nvme_command_common common;     ///< common cdw 0
        u16                     qid;        ///< queue id (cdw 10)
        u16                     rsvd10;     ///< reserved (in cdw 10)
        u32                     cwd11_15[5]; ///< reserved (cdw 11-15)
};

/// Admin command:  Create I/O Submission Queue
struct nvme_acmd_create_sq {
        struct nvme_command_common common;     ///< common cdw 0
        u16                     qid;        ///< queue id (cdw 10)
        u16                     qsize;      ///< queue size
        u16                     pc : 1;     ///< physically contiguous
        u16                     qprio : 2;  ///< interrupt enabled
        u16                     rsvd11 : 13; ///< reserved (in cdw 11)
        u16                     cqid;       ///< associated completion queue id
        u16                     nvmsetid;    ///> NVM set identifier
        u16                     rsvd12;      ///< reserved (in cdw 12)
        u32                     cdw13_15[3]; ///< reserved (cdw 13-15)
};

/// Admin command:  Get Log Page
struct nvme_acmd_get_log_page {
        struct nvme_command_common common;     ///< common cdw 0
        u8                      lid;        ///< log page id (cdw 10)
        u8                      rsvd10a;    ///< reserved (in cdw 10)
        u16                     numd : 12;  ///< number of dwords
        u16                     rsvd10b : 4; ///< reserved (in cdw 10)
        u32                     rsvd11[5];  ///< reserved (cdw 11-15)
} nvme_acmd_get_log_page_t;

/// Admin command:  Create I/O Completion Queue
struct nvme_acmd_create_cq {
        struct nvme_command_common common;     ///< common cdw 0
        u16                     qid;        ///< queue id (cdw 10)
        u16                     qsize;      ///< queue size
        u16                     pc : 1;     ///< physically contiguous
        u16                     ien : 1;    ///< interrupt enabled
        u16                     rsvd11 : 14; ///< reserved (in cdw 11)
        u16                     iv;         ///< interrupt vector
        u32                     cdw12_15[4]; ///< reserved (cdw 12-15)
};

/// Admin command:  Identify
struct nvme_acmd_identify {
        struct nvme_command_common common;     ///< common cdw 0
        u32                     cns;        ///< controller or namespace (cdw 10)
        u32                     cdw11_15[5]; ///< reserved (cdw 11-15)
};

/// Admin command:  Abort
struct nvme_acmd_abort {
        struct nvme_command_common common;     ///< common cdw 0
        u16                     sqid;       ///< submission queue id (cdw 10)
        u16                     cid;        ///< command id
        u32                     cdw11_15[5]; ///< reserved (cdw 11-15)
};

/// Submission queue entry
union nvme_sq_entry {
        struct nvme_command_rw        rw;         ///< read/write command

        struct nvme_acmd_abort        abort;      ///< admin abort command
        struct nvme_acmd_create_cq    create_cq;  ///< admin create IO completion queue
        struct nvme_acmd_create_sq    create_sq;  ///< admin create IO submission queue
        struct nvme_acmd_delete_ioq   delete_ioq; ///< admin delete IO queue
        struct nvme_acmd_identify     identify;   ///< admin identify command
        struct nvme_acmd_get_log_page get_log_page; ///< get log page command
};

/// Completion queue entry
struct nvme_cq_entry {
        u32                     cs;         ///< command specific
        u32                     rsvd;       ///< reserved
        u16                     sqhd;       ///< submission queue head
        u16                     sqid;       ///< submission queue id
        u16                     cid;        ///< command id
        union {
                u16                 psf;        ///< phase bit and status field
                struct {
                        u16             p : 1;      ///< phase tag id
                        u16             sc : 8;     ///< status code
                        u16             sct : 3;    ///< status code type
                        u16             rsvd3 : 2;  ///< reserved
                        u16             m : 1;      ///< more
                        u16             dnr : 1;    ///< do not retry
                };
        };
};

/// Queue context (a submission-completion queue pair context)
struct nvme_queue {
        int                     id;         ///< queue id
        int                     size;       ///< queue size
        union nvme_sq_entry     *sq;         ///< submission queue
        struct nvme_cq_entry    *cq;         ///< completion queue
        dma_addr_t              sq_phy;
        dma_addr_t              cq_phy;
        u32                     *sq_doorbell; ///< submission queue doorbell
        u32                     *cq_doorbell; ///< completion queue doorbell
        int                     sq_tail;    ///< submission queue tail
        int                     cq_head;    ///< completion queue head
        int                     cq_phase;   ///< completion queue phase bit
};

struct nvme_driver_data {
        struct pci_dev *pdev;
        struct cdev cdev;
        resource_size_t bar_addr;
        resource_size_t bar_len;
        struct nvme_controller_reg *csr;
        union nvme_controller_cap cap;
        struct nvme_queue *admin_queue;
        struct nvme_queue *io_queue;
        struct nvme_queue *fpga_queue;
};

static int nvme_open(struct inode *inode, struct file *file);
static int nvme_release(struct inode *inode, struct file *file);
static long nvme_ioctl(struct file *file, unsigned int cmd, unsigned long arg);

static int setup_fpga_io_queue(struct pci_dev *pdev, struct nvme_driver_data *nvme_data, dma_addr_t sq_addr, dma_addr_t cq_addr);
static void release_fpga_io_queue(struct pci_dev *pdev, struct nvme_driver_data *nvme_data);

static void submit_cmd(struct nvme_queue *queue, union nvme_sq_entry *cmd);
static int wait_for_cmd(struct nvme_queue *queue, int timeout);

static struct file_operations nvme_fops = {
        .open = nvme_open,
        .release = nvme_release,
        .unlocked_ioctl = nvme_ioctl,
};

static int nvme_open(struct inode *inode, struct file *file)
{
        struct nvme_driver_data *nvme_data;

        nvme_data = container_of(inode->i_cdev, struct nvme_driver_data, cdev);
        dev_info(&nvme_data->pdev->dev, "Opening device file...\n");

        file->private_data = nvme_data;
        return 0;
}

static int nvme_release(struct inode *inode, struct file *file)
{
        struct nvme_driver_data *nvme_data;
        nvme_data = container_of(inode->i_cdev, struct nvme_driver_data, cdev);
        dev_info(&nvme_data->pdev->dev, "Closing device file...\n");
        return 0;
}

/**
 * Write data from buffer in cmd to the NVMe device
 *
 * @param pdev PCIe device struct
 * @param nvme_data NVMe driver data struct
 * @param cmd IOCTL command
 */
static void write_to_nvme(struct pci_dev *pdev, struct nvme_driver_data *nvme_data, struct ioctl_nvme_cmd *cmd)
{
        int res = 0, i;
        u64 buf_size, off, len;
        u64* prp;
        void* data;
        dma_addr_t prp_phy, data_phy;
        struct nvme_command_rw nvme_cmd = {0};

        dev_info(&pdev->dev, "Write %lld Bytes to NVMe at address 0x%llx\n", cmd->len, cmd->nvme_addr);

        // allocate DMA-able memory for PRP list and data buffer (max 1 MB per transfer)
        buf_size = cmd->len > (1 << 20) ? 1 << 20 : cmd->len;
        prp = dma_alloc_coherent(&pdev->dev, 4096, &prp_phy, GFP_KERNEL);
        if (!prp) {
                dev_err(&pdev->dev, "Failed to allocate memory for PRP list\n");
                res = -ENOMEM;
                goto fail_prp;
        }
        data = dma_alloc_coherent(&pdev->dev, buf_size, &data_phy, GFP_KERNEL);
        if (!data) {
                dev_err(&pdev->dev, "Failed to allocate memory for DMA buffer\n");
                res = -ENOMEM;
                goto fail_buf;
        }

        // populate PRP list with PCIe addresses to 4K data pages
        off = 4096;
        for (i = 0; off < buf_size; ++i, off += 4096) {
                prp[i] = data_phy + off;
        }

        // write data in chunks of 1 MB
        nvme_cmd.common.opc = NVME_CMD_WRITE;
        nvme_cmd.common.prp1 = data_phy;
        nvme_cmd.common.nsid = 1;
        off = 0;
        while (off < cmd->len) {
                // copy user data from user space (max 1 MB)
                len = cmd->len - off;
                len = len > (1 << 20) ? 1 << 20 : len;
                res = copy_from_user(data, (void __user *)cmd->buf + off, len);
                if (res) {
                        dev_err(&pdev->dev, "Failed to copy data from user space\n");
                        res = -EAGAIN;
                        goto fail_transfer;
                }

                // PRP list required for transfers longer than 2x4K, include second
                // 4K page in command otherwise
                if (len > 2 * 4096)
                        nvme_cmd.common.prp2 = prp_phy;
                else
                        nvme_cmd.common.prp2 = data_phy + 4096;
                nvme_cmd.slba = (cmd->nvme_addr + off) / 512;
                nvme_cmd.nlb = len / 512 - 1;

                // submit command to IO queue and wait for completion
                submit_cmd(nvme_data->io_queue, (union nvme_sq_entry *)&nvme_cmd);
                res = wait_for_cmd(nvme_data->io_queue, 1000);
                if (res) {
                        dev_err(&pdev->dev, "Failed to complete NVMe command\n");
                        goto fail_transfer;
                }
                off += len;
        }

fail_transfer:
        dma_free_coherent(&pdev->dev, buf_size, data, data_phy);
fail_buf:
        dma_free_coherent(&pdev->dev, 4096, prp, prp_phy);
fail_prp:
        cmd->status = res;
}

/**
 * Read data from NVMe device and return in provided buffer in command
 *
 * @param pdev PCIe device struct
 * @param nvme_data NVMe driver data struct
 * @param cmd IOCTL command
 */
static void read_from_nvme(struct pci_dev *pdev, struct nvme_driver_data *nvme_data, struct ioctl_nvme_cmd *cmd)
{
        int res = 0, i;
        u64 buf_size, off, len;
        u64* prp;
        void* data;
        dma_addr_t prp_phy, data_phy;
        struct nvme_command_rw nvme_cmd = {0};

        dev_info(&pdev->dev, "Read %lld Bytes from NVMe at address 0x%llx\n", cmd->len, cmd->nvme_addr);

        // allocate DMA-able memory for PRP list and data buffer (max 1 MB per transfer)
        buf_size = cmd->len > (1 << 20) ? 1 << 20 : cmd->len;
        prp = dma_alloc_coherent(&pdev->dev, 4096, &prp_phy, GFP_KERNEL);
        if (!prp) {
                dev_err(&pdev->dev, "Failed to allocate memory for PRP list\n");
                res = -ENOMEM;
                goto fail_prp;
        }
        data = dma_alloc_coherent(&pdev->dev, buf_size, &data_phy, GFP_KERNEL);
        if (!data) {
                dev_err(&pdev->dev, "Failed to allocate memory for DMA buffer\n");
                res = -ENOMEM;
                goto fail_buf;
        }

        // populate PRP list with PCIe addresses of 4K data pages
        off = 4096;
        for (i = 0; off < buf_size; ++i, off += 4096) {
                prp[i] = data_phy + off;
        }

        // read data in chunks of 1 MB
        nvme_cmd.common.opc = NVME_CMD_READ;
        nvme_cmd.common.prp1 = data_phy;
        nvme_cmd.common.nsid = 1;
        off = 0;
        while (off < cmd->len) {
                // PRP list only required for transfers longer than 2x4K, otherwise include
                // second 4K page in IO command
                len = cmd->len - off;
                len = len > (1 << 20) ? 1 << 20 : len;
                if (len > 2 * 4096)
                        nvme_cmd.common.prp2 = prp_phy;
                else
                        nvme_cmd.common.prp2 = data_phy + 4096;
                nvme_cmd.slba = (cmd->nvme_addr + off) / 512;
                nvme_cmd.nlb = len / 512 - 1;

                // submit command to IO queue and wait for completion
                submit_cmd(nvme_data->io_queue, (union nvme_sq_entry *)&nvme_cmd);
                res = wait_for_cmd(nvme_data->io_queue, 1000);
                if (res) {
                        dev_err(&pdev->dev, "Failed to complete NVMe command\n");
                        goto fail_transfer;
                }

                // copy read data to user-space buffer
                res = copy_to_user((void __user *)cmd->buf + off, data, len);
                if (res) {
                        dev_err(&pdev->dev, "Failed to copy data to user space\n");
                        res = -EAGAIN;
                        goto fail_transfer;
                }
                off += len;
        }

fail_transfer:
        dma_free_coherent(&pdev->dev, buf_size, data, data_phy);
fail_buf:
        dma_free_coherent(&pdev->dev, 4096, prp, prp_phy);
fail_prp:
        cmd->status = res;
}

static long nvme_ioctl(struct file *file, unsigned int cmd, unsigned long arg) {
        int res;
        struct ioctl_setup_io_queue_cmd setup_cmd;
        struct ioctl_release_io_queue_cmd release_cmd;
        struct ioctl_nvme_cmd nvme_cmd;
        struct nvme_driver_data *nvme_data = file->private_data;
        struct pci_dev *pdev = nvme_data->pdev;

        if (_IOC_TYPE(cmd) != NVME_IOCTL_MAGIC || _IOC_NR(cmd) > NVME_IOCTL_MAX) {
                dev_err(&pdev->dev, "Invalid ioctl command\n");
                return -ENOTTY;
        }

        switch (cmd) {
                case NVME_GET_PCIE_BASE:
                        // return PCIe base address of NVMe controller
                        res = copy_to_user((unsigned long __user *)arg, &nvme_data->bar_addr, sizeof(nvme_data->bar_addr));
                        if (res) {
                                dev_err(&pdev->dev, "Failed to copy PCIe address to user space\n");
                                return -EAGAIN;
                        }
                        break;
                case NVME_SETUP_IO_QUEUE:
                        res = copy_from_user(&setup_cmd, (unsigned long __user *)arg, sizeof(struct ioctl_setup_io_queue_cmd));
                        if (res) {
                                dev_err(&pdev->dev, "Failed to copy ioctl args to kernel space\n");
                                return -EAGAIN;
                        }
                        if (nvme_data->fpga_queue) {
                                dev_info(&pdev->dev, "NVMe queue is already initialized\n");
                                setup_cmd.status = CREATE_IO_QUEUE_PRESENT;
                        } else {
                                res = setup_fpga_io_queue(pdev, nvme_data, setup_cmd.sq_addr, setup_cmd.cq_addr);
                                if (res) {
                                        dev_err(&pdev->dev, "Failed to setup IO queue\n");
                                        setup_cmd.status = CREATE_IO_QUEUE_FAILED;
                                } else {
                                        setup_cmd.status = CREATE_IO_QUEUE_SUCCESS;
                                }
                        }
                        res = copy_to_user((unsigned long __user *)arg, &setup_cmd, sizeof(struct ioctl_setup_io_queue_cmd));
                        if (res) {
                                dev_err(&pdev->dev, "Failed to copy ioctl result to user space\n");
                                return -EAGAIN;
                        }
                        break;
                case NVME_RELEASE_IO_QUEUE:
                        if (nvme_data->fpga_queue) {
                                release_fpga_io_queue(pdev, nvme_data);
                                release_cmd.status = RELEASE_IO_QUEUE_SUCCESS;
                        } else {
                                release_cmd.status = RELEASE_IO_QUEUE_NOT_PRESENT;
                        }
                        res = copy_to_user((unsigned long __user *)arg, &release_cmd, sizeof(struct ioctl_release_io_queue_cmd));
                        if (res) {
                                dev_err(&pdev->dev, "Failed to copy ioctl result to user space\n");
                                return -EAGAIN;
                        }
                        break;
                case NVME_WRITE:
                        res = copy_from_user(&nvme_cmd, (void __user *)arg, sizeof(struct ioctl_nvme_cmd));
                        if (res) {
                                dev_err(&pdev->dev, "Failed to copy ioctl args to kernel space\n");
                                return -EAGAIN;
                        }
                        write_to_nvme(pdev, nvme_data, &nvme_cmd);
                        res = copy_to_user((unsigned long __user *)arg, &nvme_cmd, sizeof(struct ioctl_nvme_cmd));
                        if (res) {
                                dev_err(&pdev->dev, "Failed to copy ioctl result to user space\n");
                        }
                        break;
                case NVME_READ:
                        res = copy_from_user(&nvme_cmd, (void __user *)arg, sizeof(struct ioctl_nvme_cmd));
                        if (res) {
                                dev_err(&pdev->dev, "Failed to copy ioctl args to kernel space\n");
                                return -EAGAIN;
                        }
                        read_from_nvme(pdev, nvme_data, &nvme_cmd);
                        res = copy_to_user((unsigned long __user *)arg, &nvme_cmd, sizeof(struct ioctl_nvme_cmd));
                        if (res) {
                                dev_err(&pdev->dev, "Failed to copy ioctl result to user space\n");
                        }
                        break;
        }
        return 0;
}

/**
 * Setup admin command queue in NVMe controller
 *
 * @param pdev PCIe device struct
 * @param nvme_data NVMe driver data struct
 * @return 0 - SUCCESS, error code - FAILURE
 */
static int setup_admin_queue(struct pci_dev *pdev, struct nvme_driver_data *nvme_data)
{
        int retry_count, res;
        union nvme_sq_entry *sq;
        struct nvme_cq_entry *cq;
        dma_addr_t sq_phy, cq_phy;
        struct nvme_queue *aq;
        union nvme_controller_status status;
        union nvme_adminq_attr aqa;
        union nvme_controller_config cc;

        dev_info(&pdev->dev, "Setup admin queue...\n");

        aq = devm_kzalloc(&pdev->dev, sizeof(*aq), GFP_KERNEL);
        if (!aq) {
                dev_err(&pdev->dev, "Failed to allocate queue structure for admin queue\n");
                res = -ENOMEM;
                goto fail_alloc_aq;
        }

        // allocate DMA-able memory for submission and completion queues
        sq = dma_alloc_coherent(&pdev->dev, 0x1000, &sq_phy, GFP_KERNEL);
        if (!sq) {
                dev_err(&pdev->dev, "Failed to allocate SQ\n");
                res = -ENOMEM;
                goto fail_alloc_sq;
        }
        cq = dma_alloc_coherent(&pdev->dev, 0x1000, &cq_phy, GFP_KERNEL);
        if (!cq) {
                dev_err(&pdev->dev, "Failed to allocate CQ\n");
                res = -ENOMEM;
                goto fail_alloc_cq;
        }

        // disable controller for proper reset
        dev_info(&pdev->dev, "Disable controller\n");
        iowrite32(0, &nvme_data->csr->cc.val);
        retry_count = nvme_data->cap.to;
        while (true) {
                status.val = ioread32(&nvme_data->csr->csts.val);
                if (status.rdy == 0)
                        break;
                if (retry_count < 0) {
                        dev_err(&pdev->dev, "Failed to disable NVMe controller\n");
                        res = -EACCES;
                        goto fail_disable;
                }
                msleep(500);
                --retry_count;
        }

        // enable controller
        dev_info(&pdev->dev, "Configure new admin queue\n");
        aqa.val = 0;
        aqa.asqs = 63;
        aqa.acqs = 63;
        iowrite32(aqa.val, &nvme_data->csr->aqa.val);
        writeq(sq_phy, &nvme_data->csr->asq);
        writeq(cq_phy, &nvme_data->csr->acq);

        cc.val = 0;
        cc.en = 1;
        cc.css = 0;
        cc.mps = 0;
        cc.ams = 0;
        cc.shn = 0;
        cc.iosqes = 6;
        cc.iocqes = 4;
        cc.crime = 0;
        cc.rsvd = cc.rsvd2 = 0;
        iowrite32(cc.val, &nvme_data->csr->cc.val);

        // check whether controller is enabled
        dev_info(&pdev->dev, "Check that controller is enabled\n");
        retry_count = nvme_data->cap.to;
        while (true) {
                status.val = ioread32(&nvme_data->csr->csts.val);
                if (status.rdy == 1) {
                        break;
                }
                if (retry_count < 0) {
                        dev_err(&pdev->dev, "Failed to enable NVMe controller\n");
                        res = -EACCES;
                        goto fail_enable;
                }
                msleep(500);
                --retry_count;
        }

        aq->id = 0;
        aq->size = 64;
        aq->sq = sq;
        aq->cq = cq;
        aq->sq_phy = sq_phy;
        aq->cq_phy = cq_phy;
        aq->sq_doorbell = nvme_data->csr->sq0tdbl;
        aq->cq_doorbell = nvme_data->csr->sq0tdbl + (1 << nvme_data->cap.dstrd);
        nvme_data->admin_queue = aq;

        dev_info(&pdev->dev, "SQ doorbell = 0x%llx\n", (u64)aq->sq_doorbell);
        dev_info(&pdev->dev, "CQ doorbell = 0x%llx\n", (u64)aq->cq_doorbell);

        return 0;

fail_enable:
fail_disable:
        dma_free_coherent(&pdev->dev, 0x1000, aq->cq, aq->cq_phy);
fail_alloc_cq:
        dma_free_coherent(&pdev->dev, 0x1000, aq->sq, aq->sq_phy);
fail_alloc_sq:
        devm_kfree(&pdev->dev, aq);
        nvme_data->admin_queue = NULL;
fail_alloc_aq:
        return res;
}

/**
 * Destroy admin command queue in NVMe controller
 *
 * @param pdev PCIe device struct
 * @param nvme_data NVMe driver data struct
 */
static void release_admin_queue(struct pci_dev *pdev, struct nvme_driver_data *nvme_data)
{
        int retry_count;
        union nvme_controller_config cc;
        union nvme_controller_status status;
        struct nvme_queue *aq = nvme_data->admin_queue;

        dev_info(&pdev->dev, "Release admin queue...\n");

        // disable queue
        cc.val = 0;
        iowrite32(cc.val, &nvme_data->csr->cc.val);
        retry_count = nvme_data->cap.to;
        while (true) {
                status.val = ioread32(&nvme_data->csr->csts.val);
                if (status.rdy == 0 || retry_count < 0)
                        break;
                --retry_count;
        }
        dma_free_coherent(&pdev->dev, 0x1000, aq->cq, aq->cq_phy);
        dma_free_coherent(&pdev->dev, 0x1000, aq->sq, aq->sq_phy);
        devm_kfree(&pdev->dev, aq);
        nvme_data->admin_queue = NULL;
}

/**
 * Submit NVMe command to given command queue
 *
 * @param queue NVMe queue to submit to
 * @param cmd NVMe command to submit
 */
static void submit_cmd(struct nvme_queue *queue, union nvme_sq_entry *cmd) {
        int cmd_id = queue->sq_tail;
        queue->sq[cmd_id] = *cmd;
        queue->sq[cmd_id].abort.common.cid = cmd_id;
        ++queue->sq_tail;
        if (queue->sq_tail == queue->size) {
                queue->sq_tail = 0;
        }
        iowrite32(queue->sq_tail, queue->sq_doorbell);
}

/**
 * Wait for completion of the last command in the given queue
 *
 * @param queue NVMe queue to wait for
 * @param timeout timeout to abort waiting (in multiples of 10 ms)
 * @return 0 - SUCCESS, error code - FAILURE
 */
static int wait_for_cmd(struct nvme_queue *queue, int timeout) {
        struct nvme_cq_entry *cqe = &queue->cq[queue->cq_head];
        int retry_count = timeout;
        while (true) {
                if (cqe->p != queue->cq_phase) {
                        break;
                }
                if (retry_count < 0) {
//                        dev_err(&pdev->dev, "ERROR: Timeout while waiting for command completion");
                        return -1;
                }
                msleep(10);
                --retry_count;
        }
        ++queue->cq_head;
        if (queue->cq_head == queue->size) {
                queue->cq_head = 0;
                queue->cq_phase = !queue->cq_phase;
        }
        iowrite32(queue->cq_head, queue->cq_doorbell);

        // return error code in completion entry
        if (cqe->psf & 0xfe) {
                return cqe->psf & 0xfe;
        }
        return 0;
}

/**
 * Create IO queue in NVMe controller
 *
 * @param pdev PCIe device struct
 * @param nvme_data NVMe driver data struct
 * @param sq_addr submission queue DMA address (for FPGA-hosted queue only)
 * @param cq_addr completion queue DMA address (for FPGA-hosted queue only)
 * @return 0 - SUCCESS, error code - FAILURE
 */
static int setup_io_queue(struct pci_dev *pdev, struct nvme_driver_data *nvme_data, dma_addr_t sq_addr, dma_addr_t cq_addr)
{
        int res;
        u16 qid;
        union nvme_sq_entry *sq;
        struct nvme_cq_entry *cq;
        dma_addr_t sq_phy, cq_phy;
        struct nvme_queue *aq, *ioq;
        union nvme_sq_entry create_cq_cmd = {0}, create_sq_cmd = {0}, delete_cq_cmd = {0};
        struct nvme_acmd_delete_ioq *delete_cmd;

        qid = sq_addr ? FPGA_QUEUE_ID : HOST_QUEUE_ID; // host = 2, FPGA = 1
        dev_info(&pdev->dev, "Setup IO queue with ID %d\n", qid);

        aq = nvme_data->admin_queue;
        ioq = devm_kzalloc(&pdev->dev, sizeof(*ioq), GFP_KERNEL);
        if (!ioq) {
                dev_err(&pdev->dev, "Failed to allocate queue structure for IO queue\n");
                res = -ENOMEM;
                goto fail_alloc_ioq;
        }

        if (sq_addr) {
                // FPGA-hosted queue -> use given SQ address
                sq = NULL;
                sq_phy = sq_addr;
                dev_info(&pdev->dev, "Base address of SQ = 0x%llx\n", sq_phy);
        } else {
                // allocate DMA-able memory for submission queue
                sq = dma_alloc_coherent(&pdev->dev, 0x1000, &sq_phy, GFP_KERNEL);
                if (!sq) {
                        dev_err(&pdev->dev, "Failed to allocate SQ\n");
                        res = -ENOMEM;
                        goto fail_alloc_sq;
                }
        }
        if (cq_addr) {
                // FPGA-hosted queue -> use given CQ address
                cq = NULL;
                cq_phy = cq_addr;
                dev_info(&pdev->dev, "Base address of CQ = 0x%llx\n", cq_phy);
        } else {
                // allocate DMA-able memory for completion queue
                cq = dma_alloc_coherent(&pdev->dev, 0x1000, &cq_phy, GFP_KERNEL);
                if (!cq) {
                        dev_err(&pdev->dev, "Failed to allocate CQ\n");
                        res = -ENOMEM;
                        goto fail_alloc_cq;
                }
        }

        // create CQ queue using admin command
        dev_info(&pdev->dev, "Create CQ for IO queue\n");
        create_cq_cmd.create_cq.common.opc = NVME_ACMD_CREATE_CQ;
        create_cq_cmd.create_cq.common.prp1 = cq_phy;
        create_cq_cmd.create_cq.qid = qid;
        create_cq_cmd.create_cq.qsize = 63;
        create_cq_cmd.create_cq.pc = 1;
        create_cq_cmd.create_cq.ien = 0; // do not use interrupts
        submit_cmd(aq, &create_cq_cmd);
        if (wait_for_cmd(aq, nvme_data->cap.to)) {
                dev_err(&pdev->dev, "Failed to register CQ\n");
                res = -EACCES;
                goto fail_setup_cq;
        }

        // create SQ using admin command
        dev_info(&pdev->dev, "Create SQ for IO queue\n");
        create_sq_cmd.create_sq.common.opc = NVME_ACMD_CREATE_SQ;
        create_sq_cmd.create_sq.common.prp1 = sq_phy;
        create_sq_cmd.create_sq.qid = qid;
        create_sq_cmd.create_sq.qsize = 63;
        create_sq_cmd.create_sq.pc = 1;
        create_sq_cmd.create_sq.qprio = 2;
        create_sq_cmd.create_sq.cqid = qid;
        submit_cmd(aq, &create_sq_cmd);
        if (wait_for_cmd(aq, nvme_data->cap.to)) {
                dev_err(&pdev->dev, "Failed to register CQ\n");
                res = -EACCES;
                goto fail_setup_sq;
        }

        ioq->id = qid;
        ioq->size = 64;
        ioq->sq = sq;
        ioq->cq = cq;
        ioq->sq_phy = sq_phy;
        ioq->cq_phy = cq_phy;
        ioq->sq_doorbell = nvme_data->csr->sq0tdbl + qid * 2 * (1 << nvme_data->cap.dstrd);
        ioq->cq_doorbell = ioq->sq_doorbell + (1 << nvme_data->cap.dstrd);
        if (sq_addr)
                nvme_data->fpga_queue = ioq;
        else
                nvme_data->io_queue = ioq;

        dev_info(&pdev->dev, "SQ doorbell = 0x%llx", (u64)ioq->sq_doorbell);
        dev_info(&pdev->dev, "CQ doorbell = 0x%llx", (u64)ioq->cq_doorbell);

        return 0;

fail_setup_sq:
        delete_cmd = (struct nvme_acmd_delete_ioq *)&delete_cq_cmd;
        delete_cmd->common.opc = NVME_ACMD_DELETE_CQ;
        delete_cmd->qid = qid;
        submit_cmd(aq, &delete_cq_cmd);
        if (wait_for_cmd(aq, nvme_data->cap.to)) {
                dev_err(&pdev->dev, "Failed to delete CQ after failure\n");
        }
fail_setup_cq:
        if (cq)
                dma_free_coherent(&pdev->dev, 0x1000, cq, cq_phy);
fail_alloc_cq:
        if (sq)
                dma_free_coherent(&pdev->dev, 0x1000, sq, sq_phy);
fail_alloc_sq:
        devm_kfree(&pdev->dev, aq);
fail_alloc_ioq:
        return res;
}

static int setup_host_io_queue(struct pci_dev *pdev, struct nvme_driver_data *nvme_data)
{
        return setup_io_queue(pdev, nvme_data, 0, 0);
}

static int setup_fpga_io_queue(struct pci_dev *pdev, struct nvme_driver_data *nvme_data, dma_addr_t sq_addr, dma_addr_t cq_addr)
{
        return setup_io_queue(pdev, nvme_data, sq_addr, cq_addr);
}

/**
 * Destroy IO queue in NVMe controller
 *
 * @param pdev PCIe device struct
 * @param nvme_data NVMe driver data struct
 * @param qid queue ID to destroy
 */
static void release_io_queue(struct pci_dev *pdev, struct nvme_driver_data *nvme_data, int qid) {
        struct nvme_queue *ioq, *aq;
        struct nvme_acmd_delete_ioq delete_cq_cmd = {0}, delete_sq_cmd = {0};

        if (qid == HOST_QUEUE_ID) {
                dev_info(&pdev->dev, "Release host IO queue\n");
                ioq = nvme_data->io_queue;
                if (!ioq)
                        return;
                nvme_data->io_queue = NULL;
        } else if (qid == FPGA_QUEUE_ID) {
                dev_info(&pdev->dev, "Release FPGA IO queue\n");
                ioq = nvme_data->fpga_queue;
                if (!ioq)
                        return;
                nvme_data->fpga_queue = NULL;
        } else {
                dev_err(&pdev->dev, "Invalid queue ID passed to release_io_queue\n");
                return;
        }

        // delete IO queues using admin commands
        aq = nvme_data->admin_queue;
        delete_sq_cmd.common.opc = NVME_ACMD_DELETE_SQ;
        delete_sq_cmd.qid = qid;
        submit_cmd(aq, (union nvme_sq_entry *)&delete_sq_cmd);
        if (wait_for_cmd(aq, nvme_data->cap.to)) {
                dev_err(&pdev->dev, "Failed to delete SQ with ID %d\n", qid);
                return;
        }
        delete_cq_cmd.common.opc = NVME_ACMD_DELETE_CQ;
        delete_cq_cmd.qid = qid;
        submit_cmd(aq, (union nvme_sq_entry *)&delete_cq_cmd);
        if (wait_for_cmd(aq, nvme_data->cap.to)) {
                dev_err(&pdev->dev, "Failed to delete CQ with ID %d\n", qid);
        }

        dma_free_coherent(&pdev->dev, 0x1000, ioq->cq, ioq->cq_phy);
        dma_free_coherent(&pdev->dev, 0x1000, ioq->sq, ioq->sq_phy);
        devm_kfree(&pdev->dev, ioq);
}

static void release_host_io_queue(struct pci_dev *pdev, struct nvme_driver_data *nvme_data)
{
        release_io_queue(pdev, nvme_data, HOST_QUEUE_ID);
}

static void release_fpga_io_queue(struct pci_dev *pdev, struct nvme_driver_data *nvme_data)
{
        release_io_queue(pdev, nvme_data, FPGA_QUEUE_ID);
}

static int create_chrdev(struct pci_dev *pdev, struct nvme_driver_data *nvme_data)
{
        int res;
        struct device *nvme_device;
        dev_t dev = MKDEV(major_num, 0);

        // allocate major number
        res = alloc_chrdev_region(&dev, 0, 1, DEVICE_NAME);
        major_num = MAJOR(dev);
        if (res < 0) {
                dev_err(&pdev->dev, "Failed to allocate major number\n");
                goto fail_major;
        }

        // initialize cdev
        cdev_init(&nvme_data->cdev, &nvme_fops);
        nvme_data->cdev.owner = THIS_MODULE;
        nvme_data->cdev.ops = &nvme_fops;
        res = cdev_add(&nvme_data->cdev, dev, 1);
        if (res) {
                dev_err(&pdev->dev, "Failed to initialize cdev\n");
                goto fail_initcdev;
        }

        // create device class_create
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 4, 0)
        nvme_class = class_create(THIS_MODULE, CLASS_NAME);
#else
        nvme_class = class_create(CLASS_NAME);
#endif
        if (IS_ERR(nvme_class)) {
                dev_err(&pdev->dev, "Failed to create device class\n");
                res = PTR_ERR(nvme_class);
                goto fail_class;
        }

        // create device
        nvme_device = device_create(nvme_class, NULL, dev, NULL, DEVICE_NAME);
        if (IS_ERR(nvme_device)) {
                dev_err(&pdev->dev, "Failed to create device\n");
                res = PTR_ERR(nvme_device);
                goto fail_device;
        }

        return 0;

fail_device:
        class_destroy(nvme_class);
fail_class:
        cdev_del(&nvme_data->cdev);
fail_initcdev:
fail_major:
        return res;
}

static void destroy_chrdev(struct nvme_driver_data *nvme_data)
{
        device_destroy(nvme_class, MKDEV(major_num, 0));
        class_destroy(nvme_class);
        cdev_del(&nvme_data->cdev);
}

static int nvme_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
        int res;
        struct nvme_driver_data *nvme_data;

        // allocate device struct
        nvme_data = devm_kzalloc(&pdev->dev, sizeof(*nvme_data), GFP_KERNEL);
        if (!nvme_data) {
                dev_err(&pdev->dev, "Failed to allocate device data structure\n");
                res = -ENOMEM;
                goto fail_alloc;
        }
        dev_set_drvdata(&pdev->dev, nvme_data);
        nvme_data->pdev = pdev;

        res = pci_enable_device(pdev);
        if (res) {
                dev_err(&pdev->dev, "Failed to enable PCIe device\n");
                goto fail_enable;
        }
        pci_set_master(pdev);

        // map control register
        res = pci_request_regions(pdev, DEVICE_NAME);
        if (res) {
                dev_err(&pdev->dev, "Failed to request PCIe regions\n");
                res = -EACCES;
                goto fail_region;
        }

        nvme_data->bar_addr = pci_resource_start(pdev, 0);
        nvme_data->bar_len = pci_resource_len(pdev, 0);
        dev_info(&pdev->dev, "Remap control register at address 0x%llx with size 0x%lx\n", nvme_data->bar_addr, sizeof(*nvme_data->csr));
        nvme_data->csr = ioremap(nvme_data->bar_addr, sizeof(*nvme_data->csr));
        if (!nvme_data->csr) {
                dev_err(&pdev->dev, "Failed to map control registers\n");
                res = -EACCES;
                goto fail_mapcsr;
        }
        nvme_data->cap.val = readq(&nvme_data->csr->cap.val);

        // create character device
        res = create_chrdev(pdev, nvme_data);
        if (res) {
                goto fail_dev;
        }

        // create admin command queue
        res = setup_admin_queue(pdev, nvme_data);
        if (res) {
                goto fail_adminqueue;
        }

        // create IO queue for host access by default
        res = setup_host_io_queue(pdev, nvme_data);
        if (res) {
                goto fail_ioqueue;
        }

        return 0;

fail_ioqueue:
        release_admin_queue(pdev, nvme_data);
fail_adminqueue:
        destroy_chrdev(nvme_data);
fail_dev:
        iounmap(nvme_data->csr);
fail_mapcsr:
        pci_release_regions(pdev);
fail_region:
        pci_clear_master(pdev);
        pci_disable_device(pdev);

fail_enable:
        devm_kfree(&pdev->dev, nvme_data);
fail_alloc:
        return res;
}

static void nvme_remove(struct pci_dev *pdev)
{
        struct nvme_driver_data *nvme_data = dev_get_drvdata(&pdev->dev);

        // silently fails if FPGA queue not setup
        release_fpga_io_queue(pdev, nvme_data);
        release_host_io_queue(pdev, nvme_data);
        release_admin_queue(pdev, nvme_data);
        destroy_chrdev(nvme_data);
        iounmap(nvme_data->csr);
        pci_release_regions(pdev);
        pci_clear_master(pdev);
        pci_disable_device(pdev);
        devm_kfree(&pdev->dev, nvme_data);
}

static struct pci_device_id nvme_ids[] = {
        {PCI_DEVICE(0x144d, 0xa80C),},
        {0,}
};

static struct pci_driver nvme_driver = {
        .name = DEVICE_NAME,
        .id_table = nvme_ids,
        .probe = nvme_probe,
        .remove = nvme_remove,
};

static int __init nvme_init(void)
{
        int res;
        pr_info("nvme-host-driver: Registering driver...\n");
        res = pci_register_driver(&nvme_driver);
        if (res) {
                pr_err("nvme-host-driver: Failed to load driver with error code %d\n", res);
                return res;
        }
        return 0;
}

static void __exit nvme_exit(void)
{
        pr_info("nvme-host-driver: Unregistering driver...\n");
        pci_unregister_driver(&nvme_driver);
}

module_init(nvme_init);
module_exit(nvme_exit);