#include "usbcontrol.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>

static io_service_t find_device(uint16_t vid, uint16_t pid) {
    const char *classes[] = {"IOUSBHostDevice", kIOUSBDeviceClassName};
    for (int c = 0; c < 2; c++) {
        CFMutableDictionaryRef match = IOServiceMatching(classes[c]);
        if (!match) continue;
        int v = vid, p = pid;
        CFNumberRef nv = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &v);
        CFNumberRef np = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &p);
        CFDictionarySetValue(match, CFSTR(kUSBVendorID), nv);
        CFDictionarySetValue(match, CFSTR(kUSBProductID), np);
        CFRelease(nv);
        CFRelease(np);
        io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, match); // consumes match
        if (s) return s;
    }
    return 0;
}

int usbctl_present(uint16_t vendorID, uint16_t productID) {
    io_service_t s = find_device(vendorID, productID);
    if (!s) return 0;
    IOObjectRelease(s);
    return 1;
}

static IOUSBDevRequestTO make_request(uint8_t requestType, uint8_t request, uint16_t value, uint16_t index,
                                      void *data, uint16_t length, uint32_t timeoutMs) {
    IOUSBDevRequestTO r;
    r.bmRequestType = requestType;
    r.bRequest = request;
    r.wValue = value;
    r.wIndex = index;
    r.wLength = length;
    r.pData = data;
    r.wLenDone = 0;
    r.noDataTimeout = timeoutMs;
    r.completionTimeout = timeoutMs;
    return r;
}

static int via_interface(IOUSBDeviceInterface650 **dev, IOUSBDevRequestTO *req) {
    IOUSBFindInterfaceRequest find;
    find.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    find.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    find.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    find.bAlternateSetting = kIOUSBFindInterfaceDontCare;
    io_iterator_t it = 0;
    IOReturn kr = (*dev)->CreateInterfaceIterator(dev, &find, &it);
    if (kr != kIOReturnSuccess) return kr;
    io_service_t intfService;
    int result = kIOReturnNotFound;
    while ((intfService = IOIteratorNext(it))) {
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        kr = IOCreatePlugInInterfaceForService(intfService, kIOUSBInterfaceUserClientTypeID,
                                               kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(intfService);
        if (kr != kIOReturnSuccess || !plugin) continue;
        IOUSBInterfaceInterface650 **intf = NULL;
        (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID650), (LPVOID *)&intf);
        IODestroyPlugInInterface(plugin);
        if (!intf) continue;
        UInt8 number = 0xFF;
        (*intf)->GetInterfaceNumber(intf, &number);
        if (number == 0) {
            // Control requests on pipe 0 do not need the interface to be opened.
            result = (*intf)->ControlRequestTO(intf, 0, req);
        }
        (*intf)->Release(intf);
        if (number == 0) break;
    }
    IOObjectRelease(it);
    return result;
}

int usbctl_transfer(uint16_t vendorID, uint16_t productID,
                    uint8_t requestType, uint8_t request,
                    uint16_t value, uint16_t index,
                    void *data, uint16_t length, uint32_t timeoutMs) {
    io_service_t service = find_device(vendorID, productID);
    if (!service) return kIOReturnNoDevice;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess || !plugin) return kr ? kr : kIOReturnError;

    IOUSBDeviceInterface650 **dev = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&dev);
    IODestroyPlugInInterface(plugin);
    if (!dev) return kIOReturnUnsupported;

    IOUSBDevRequestTO req = make_request(requestType, request, value, index, data, length, timeoutMs);
    kr = (*dev)->DeviceRequestTO(dev, &req);
    if (kr != kIOReturnSuccess) {
        req = make_request(requestType, request, value, index, data, length, timeoutMs);
        IOReturn kr2 = via_interface(dev, &req);
        if (kr2 == kIOReturnSuccess) kr = kIOReturnSuccess;
    }
    (*dev)->Release(dev);
    return kr;
}

static void cfstring_prop(io_service_t s, const char *key, char *out, int size) {
    out[0] = 0;
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, k, kCFAllocatorDefault, 0);
    CFRelease(k);
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString((CFStringRef)v, out, size, kCFStringEncodingUTF8);
    if (v) CFRelease(v);
}

static int int_prop(io_service_t s, const char *key) {
    int value = -1;
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, k, kCFAllocatorDefault, 0);
    CFRelease(k);
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &value);
    if (v) CFRelease(v);
    return value;
}

int usbctl_list(char *buf, int bufSize) {
    if (bufSize <= 0) return 0;
    buf[0] = 0;
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) != KERN_SUCCESS) return 0;
    int count = 0, used = 0;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        char name[128], vendor[128], serial[64];
        cfstring_prop(s, "USB Product Name", name, sizeof name);
        cfstring_prop(s, "USB Vendor Name", vendor, sizeof vendor);
        cfstring_prop(s, "USB Serial Number", serial, sizeof serial);
        int vid = int_prop(s, "idVendor"), pid = int_prop(s, "idProduct");
        int n = snprintf(buf + used, bufSize - used, "%04X:%04X  %s  (%s)%s%s\n", vid & 0xFFFF, pid & 0xFFFF,
                         name[0] ? name : "?", vendor[0] ? vendor : "?", serial[0] ? "  SN " : "", serial);
        if (n > 0 && used + n < bufSize) used += n;
        count++;
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return count;
}
