import Foundation
import IOKit

struct HuaweiUSBDevice: Equatable {
    let productID: Int
    let name: String

    var displayName: String {
        if name.isEmpty || name == "HUAWEI Mobile" {
            switch productID {
            case 0x1446: return "HUAWEI CD-ROM installer"
            case 0x1003, 0x14AC: return "HUAWEI Mobile"
            default: return String(format: "HUAWEI device %04x", productID)
            }
        }
        return name
    }

    var isInstallerMode: Bool { productID == 0x1446 }
    var isModemMode: Bool { productID == 0x1003 || productID == 0x14AC }
}

enum HardwareProbe {
    static func huaweiDevices() -> [HuaweiUSBDevice] {
        var found: [HuaweiUSBDevice] = []
        for serviceClass in ["IOUSBHostDevice", "AppleUSBDevice"] {
            guard let match = IOServiceMatching(serviceClass) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                defer { IOObjectRelease(service) }

                guard let vendor = intProperty(service, "idVendor"), vendor == 0x12D1 else {
                    continue
                }
                let product = intProperty(service, "idProduct") ?? 0
                let name = stringProperty(service, "USB Product Name")
                    ?? stringProperty(service, "kUSBProductString")
                    ?? ""
                let device = HuaweiUSBDevice(productID: product, name: name)
                if !found.contains(device) {
                    found.append(device)
                }
            }
        }
        return found
    }

    static func driverLoaded() -> Bool {
        for serviceClass in ["HuaweiDataCardACMData", "HuaweiDataCardDriver"] {
            guard let match = IOServiceMatching(serviceClass) else { continue }
            var iterator: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS {
                let service = IOIteratorNext(iterator)
                IOObjectRelease(iterator)
                if service != 0 {
                    IOObjectRelease(service)
                    return true
                }
            }
        }
        return false
    }

    static func huaweiSerialPorts() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else {
            return []
        }
        return names
            .filter { $0.hasPrefix("cu.") && $0.lowercased().contains("huawei") }
            .sorted()
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        return value as? String
    }
}
