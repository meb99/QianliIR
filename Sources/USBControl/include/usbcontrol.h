#ifndef USBCONTROL_H
#define USBCONTROL_H

#include <stdint.h>

/// Sends one USB control transfer to the first device with the given vendor/product id.
/// Tries a device-level request first and falls back to the VideoControl interface,
/// so the macOS camera driver can keep streaming meanwhile.
/// Returns 0 on success, otherwise an IOReturn / negative error code.
int usbctl_transfer(uint16_t vendorID, uint16_t productID,
                    uint8_t requestType, uint8_t request,
                    uint16_t value, uint16_t index,
                    void *data, uint16_t length, uint32_t timeoutMs);

/// 1 if a device with this vendor/product id is connected.
int usbctl_present(uint16_t vendorID, uint16_t productID);

#endif
