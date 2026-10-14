import CoreGraphics
import Foundation
import Testing
@testable import BetterSim

/// devicectl output. The Wi-Fi iPhone, the empty list and the error are real output from Xcode 26.6 with the
/// names, serial numbers and identifiers replaced. The rest follow the same schema.
enum DeviceFixtures {
    static let iPhoneOnWiFi = """
    {
      "info" : {
        "arguments" : [ "devicectl", "list", "devices", "--json-output", "list-devices.json" ],
        "commandType" : "devicectl.list.devices",
        "environment" : { },
        "jsonVersion" : 3,
        "outcome" : "success",
        "version" : "518.33"
      },
      "result" : {
        "devices" : [
          {
            "capabilities" : [
              { "featureIdentifier" : "com.apple.coredevice.feature.acquireusageassertion", "name" : "Acquire Usage Assertion" },
              { "featureIdentifier" : "com.apple.coredevice.feature.connectdevice", "name" : "Connect to Device" },
              { "featureIdentifier" : "com.apple.coredevice.feature.tags", "name" : "Modify Tags" },
              { "featureIdentifier" : "com.apple.coredevice.feature.default.user.credentials", "name" : "Modify credentials for default users for a device" },
              { "featureIdentifier" : "com.apple.coredevice.feature.unpairdevice", "name" : "Unpair Device" }
            ],
            "connectionProperties" : {
              "authenticationType" : "manualPairing",
              "isMobileDeviceOnly" : false,
              "lastConnectionDate" : "2026-09-14T18:15:00.000Z",
              "pairingState" : "paired",
              "potentialHostnames" : [
                "Test-iPhone.coredevice.local",
                "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D.coredevice.local",
                "00008140-001A2B3C4D5E801E.coredevice.local"
              ],
              "transportType" : "localNetwork",
              "tunnelState" : "disconnected",
              "tunnelTransportProtocol" : "tcp"
            },
            "deviceProperties" : {
              "bootedFromSnapshot" : true,
              "bootedSnapshotName" : "com.apple.os.update-0000000000000000000000000000000000000000000000000000000000000000",
              "ddiServicesAvailable" : false,
              "developerModeStatus" : "enabled",
              "hasInternalOSBuild" : false,
              "name" : "Test iPhone",
              "osBuildUpdate" : "23H30",
              "osVersionNumber" : "26.7.1",
              "rootFileSystemIsWritable" : false,
              "screenViewingURL" : "devices://device/open?id=0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
              "supportsCheckedAllocations" : false
            },
            "hardwareProperties" : {
              "cpuType" : { "name" : "arm64e", "subType" : 2, "type" : 16777228 },
              "deviceType" : "iPhone",
              "ecid" : 1234567890123456,
              "hardwareModel" : "D93AP",
              "internalStorageCapacity" : 128000000000,
              "isProductionFused" : true,
              "marketingName" : "iPhone 16 Pro",
              "platform" : "iOS",
              "productType" : "iPhone17,1",
              "reality" : "physical",
              "serialNumber" : "XXXXXXXXXX",
              "supportedCPUTypes" : [
                { "name" : "arm64e", "subType" : 2, "type" : 16777228 },
                { "name" : "arm64", "subType" : 0, "type" : 16777228 }
              ],
              "supportedDeviceFamilies" : [ 1 ],
              "thinningProductType" : "iPhone17,1",
              "udid" : "00008140-001A2B3C4D5E801E"
            },
            "identifier" : "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
            "tags" : [ ],
            "visibilityClass" : "default"
          }
        ]
      }
    }
    """

    static let emptyList = """
    {
      "info" : {
        "arguments" : [ "devicectl", "list", "devices", "--filter", "hardwareProperties.platform == 'none'", "--json-output", "empty.json" ],
        "commandType" : "devicectl.list.devices",
        "environment" : { },
        "jsonVersion" : 3,
        "outcome" : "success",
        "version" : "518.33"
      },
      "result" : {
        "devices" : [ ]
      }
    }
    """

    /// An iPad on USB, an iPhone that's switched off, an unpaired iPhone and a watch, which isn't for this window.
    static let mixedList = """
    {
      "info" : { "commandType" : "devicectl.list.devices", "jsonVersion" : 3, "outcome" : "success", "version" : "518.33" },
      "result" : {
        "devices" : [
          {
            "connectionProperties" : { "pairingState" : "paired", "tunnelState" : "unavailable" },
            "deviceProperties" : { "name" : "Old iPhone", "osVersionNumber" : "18.6" },
            "hardwareProperties" : {
              "deviceType" : "iPhone", "marketingName" : "iPhone 13 mini", "platform" : "iOS", "productType" : "iPhone14,4",
              "reality" : "physical", "udid" : "00008110-000A11223344556E"
            },
            "identifier" : "AAAAAAAA-0000-4000-8000-000000000001"
          },
          {
            "connectionProperties" : {
              "pairingState" : "paired", "transportType" : "wired", "tunnelState" : "connected", "tunnelTransportProtocol" : "tcp"
            },
            "deviceProperties" : { "name" : "Studio iPad", "osVersionNumber" : "26.0", "developerModeStatus" : "enabled" },
            "hardwareProperties" : {
              "deviceType" : "iPad", "marketingName" : "iPad Pro 11-inch (M4)", "platform" : "iOS", "productType" : "iPad16,3",
              "reality" : "physical", "udid" : "00008132-000B22334455667E"
            },
            "identifier" : "AAAAAAAA-0000-4000-8000-000000000002"
          },
          {
            "connectionProperties" : { "pairingState" : "unpaired", "transportType" : "wired", "tunnelState" : "disconnected" },
            "deviceProperties" : { "name" : "New iPhone", "osVersionNumber" : "26.1" },
            "hardwareProperties" : {
              "deviceType" : "iPhone", "marketingName" : "iPhone 17", "platform" : "iOS", "productType" : "iPhone18,3", "reality" : "physical"
            },
            "identifier" : "AAAAAAAA-0000-4000-8000-000000000003"
          },
          {
            "connectionProperties" : { "pairingState" : "paired", "transportType" : "localNetwork", "tunnelState" : "disconnected" },
            "deviceProperties" : { "name" : "Watch", "osVersionNumber" : "26.0" },
            "hardwareProperties" : {
              "deviceType" : "appleWatch", "marketingName" : "Apple Watch Series 11", "platform" : "watchOS", "productType" : "Watch7,18",
              "reality" : "physical"
            },
            "identifier" : "AAAAAAAA-0000-4000-8000-000000000004"
          }
        ]
      }
    }
    """

    /// What `device info apps` wrote while the device was locked.
    static let lockedDevice = """
    {
      "error" : {
        "code" : 12040,
        "domain" : "com.apple.dt.CoreDeviceError",
        "userInfo" : {
          "DeviceIdentifier" : { "string" : "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D" },
          "NSLocalizedDescription" : { "string" : "The developer disk image could not be mounted on this device." },
          "NSUnderlyingError" : {
            "error" : {
              "code" : 12040,
              "domain" : "com.apple.dt.CoreDeviceError",
              "userInfo" : {
                "DDIBuildUpdate" : { "string" : "17F113 (developerTools)" },
                "DDIPath" : { "string" : "/Library/Developer/DeveloperDiskImages/iOS_DDI" },
                "DeviceFusing" : { "string" : "prod" },
                "DeviceIdentifier" : { "string" : "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D" },
                "NSLocalizedDescription" : { "string" : "The developer disk image could not be mounted on this device." },
                "NSURL" : { "url" : "file:///Library/Developer/DeveloperDiskImages/iOS_DDI/" },
                "NSUnderlyingError" : {
                  "error" : {
                    "code" : -402652958,
                    "domain" : "com.apple.mobiledevice",
                    "userInfo" : {
                      "FunctionName" : { "string" : "AMDeviceRemoteMountPersonalizedBundle" },
                      "LineNumber" : { "int" : 2127 },
                      "NSLocalizedDescription" : {
                        "string" : "Error mounting image: 0xe80000e2 (kAMDMobileImageMounterDeviceLocked: The device is locked.)"
                      },
                      "NSUnderlyingError" : {
                        "error" : {
                          "code" : -402652958,
                          "domain" : "com.apple.mobiledevice",
                          "userInfo" : {
                            "FunctionName" : { "string" : "-[PersonalizedImage mountImage:]" },
                            "LineNumber" : { "int" : 2049 },
                            "NSLocalizedDescription" : {
                              "string" : "Failed to mount image: 0xe80000e2 (kAMDMobileImageMounterDeviceLocked: The device is locked.)"
                            }
                          }
                        }
                      }
                    }
                  }
                },
                "Options" : {
                  "dictionary" : {
                    "MountedBundlePath" : { "url" : "file:///Library/Developer/DeveloperDiskImages/iOS_DDI/" },
                    "UseCredentials" : { "bool" : false }
                  }
                }
              }
            }
          }
        }
      },
      "info" : {
        "arguments" : [ "devicectl", "device", "info", "apps", "--device", "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D" ],
        "commandType" : "devicectl.device.info.apps",
        "environment" : { },
        "jsonVersion" : 3,
        "outcome" : "failed",
        "version" : "518.33"
      }
    }
    """

    static let apps = """
    {
      "info" : { "commandType" : "devicectl.device.info.apps", "jsonVersion" : 3, "outcome" : "success", "version" : "518.33" },
      "result" : {
        "apps" : [
          {
            "appClip" : false, "builtByDeveloper" : false, "bundleIdentifier" : "com.example.store", "bundleVersion" : "812",
            "defaultApp" : false, "hidden" : false, "internalApp" : false, "name" : "Store App", "removable" : true,
            "url" : "file:///private/var/containers/Bundle/Application/5C1D0E2F-3A4B-4C5D-8E6F-7A8B9C0D1E2F/Store%20App.app/",
            "version" : "4.2"
          },
          {
            "appClip" : false, "builtByDeveloper" : true, "bundleIdentifier" : "com.example.demo", "bundleVersion" : "7",
            "defaultApp" : false, "hidden" : false, "internalApp" : false, "name" : "Demo", "removable" : true,
            "url" : "file:///private/var/containers/Bundle/Application/9F2E1D0C-B3A4-4958-A6B7-C8D9E0F1A2B3/Demo.app/",
            "version" : "1.0"
          },
          {
            "appClip" : true, "builtByDeveloper" : true, "bundleIdentifier" : "com.example.demo.clip", "bundleVersion" : "7",
            "defaultApp" : false, "hidden" : false, "internalApp" : false, "name" : "Demo Clip", "removable" : true,
            "url" : "file:///private/var/containers/Bundle/Application/1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D/Demo%20Clip.app/",
            "version" : "1.0"
          }
        ],
        "defaultAppsIncluded" : false,
        "deviceIdentifier" : "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
        "hiddenAppsIncluded" : false,
        "internalAppsIncluded" : false,
        "removableAppsIncluded" : true
      }
    }
    """

    static let processes = """
    {
      "info" : { "commandType" : "devicectl.device.info.processes", "jsonVersion" : 3, "outcome" : "success", "version" : "518.33" },
      "result" : {
        "deviceIdentifier" : "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
        "runningProcesses" : [
          { "executable" : "file:///sbin/launchd", "processIdentifier" : 1 },
          { "executable" : "file:///private/var/containers/Bundle/Application/9F2E1D0C-B3A4-4958-A6B7-C8D9E0F1A2B3/Demo.app/Demo", "processIdentifier" : 412 },
          {
            "executable" : "file:///private/var/containers/Bundle/Application/9F2E1D0C-B3A4-4958-A6B7-C8D9E0F1A2B3/Demo.app/PlugIns/Widget.appex/Widget",
            "processIdentifier" : 415
          },
          {
            "executable" : "file:///private/var/containers/Bundle/Application/5C1D0E2F-3A4B-4C5D-8E6F-7A8B9C0D1E2F/Store%20App.app/Store%20App",
            "processIdentifier" : 520
          },
          { "processIdentifier" : 77 }
        ]
      }
    }
    """

    static let install = """
    {
      "info" : { "commandType" : "devicectl.device.install.app", "jsonVersion" : 3, "outcome" : "success", "version" : "518.33" },
      "result" : {
        "deviceIdentifier" : "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
        "installedApplications" : [
          {
            "bundleID" : "com.example.demo",
            "databaseSequenceNumber" : 2948,
            "databaseUUID" : "8D3F2A1B-0C9D-4E8F-A7B6-C5D4E3F2A1B0",
            "installationURL" : "file:///private/var/containers/Bundle/Application/9F2E1D0C-B3A4-4958-A6B7-C8D9E0F1A2B3/Demo.app/",
            "launchServicesIdentifier" : "unknown",
            "options" : { }
          }
        ]
      }
    }
    """

    static let deviceTypes = """
    {
      "devicetypes" : [
        {
          "productFamily" : "iPhone",
          "bundlePath" : "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 16 Pro.simdevicetype",
          "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro",
          "modelIdentifier" : "iPhone17,1",
          "name" : "iPhone 16 Pro"
        },
        {
          "productFamily" : "iPad",
          "bundlePath" : "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPad Pro 13-inch (M5) (16GB).simdevicetype",
          "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-16GB",
          "modelIdentifier" : "iPad17,4",
          "name" : "iPad Pro 13-inch (M5) (16GB)"
        },
        {
          "productFamily" : "iPad",
          "bundlePath" : "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPad Pro 13-inch (M5).simdevicetype",
          "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
          "modelIdentifier" : "iPad17,4",
          "name" : "iPad Pro 13-inch (M5)"
        },
        {
          "productFamily" : "iPad",
          "bundlePath" : "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPad Pro 11-inch (M4) (16GB).simdevicetype",
          "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-16GB",
          "modelIdentifier" : "iPad16,4",
          "name" : "iPad Pro 11-inch (M4) (16GB)"
        },
        {
          "productFamily" : "iPad",
          "bundlePath" : "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPad Pro 11-inch (M4).simdevicetype",
          "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-8GB",
          "modelIdentifier" : "iPad16,4",
          "name" : "iPad Pro 11-inch (M4)"
        }
      ]
    }
    """

    static func device(name: String = "Test iPhone", udid: String? = "00008140-001A2B3C4D5E801E") -> PhysicalDevice {
        PhysicalDevice(
            identifier: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D", name: name, model: "iPhone 16 Pro", modelIdentifier: "iPhone17,1",
            deviceType: "iPhone", osVersion: "26.7.1", udid: udid, connection: .usb
        )
    }
}

struct PhysicalDeviceListTests {
    @Test func readsAnIPhonePairedOverWiFi() throws {
        let devices = try PhysicalDevice.parseList(Data(DeviceFixtures.iPhoneOnWiFi.utf8))
        let device = try #require(devices.first)
        #expect(devices.count == 1)
        #expect(device.identifier == "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")
        #expect(device.name == "Test iPhone")
        #expect(device.model == "iPhone 16 Pro")
        #expect(device.modelIdentifier == "iPhone17,1")
        #expect(device.udid == "00008140-001A2B3C4D5E801E")
        #expect(device.connection == .wifi)
        #expect(device.subtitle == "iPhone 16 Pro · iOS 26.7.1")
        #expect(device.symbol == "iphone")
    }

    @Test func readsAnEmptyList() throws {
        #expect(try PhysicalDevice.parseList(Data(DeviceFixtures.emptyList.utf8)).isEmpty)
    }

    @Test func keepsIPhonesAndIPadsWithReachableOnesFirst() throws {
        let devices = try PhysicalDevice.parseList(Data(DeviceFixtures.mixedList.utf8))
        #expect(devices.map(\.name) == ["Studio iPad", "New iPhone", "Old iPhone"])
        #expect(devices.map(\.connection) == [.usb, .notPaired, .offline])
        #expect(devices[0].subtitle == "iPad Pro 11-inch (M4) · iPadOS 26.0")
        #expect(devices[0].symbol == "ipad")
    }

    @Test func namesTheConnection() {
        #expect(PhysicalDevice.connection(pairingState: "paired", transportType: "wired", tunnelState: "connected") == .usb)
        #expect(PhysicalDevice.connection(pairingState: "paired", transportType: "wired", tunnelState: "disconnected") == .usb)
        #expect(PhysicalDevice.connection(pairingState: "paired", transportType: "localNetwork", tunnelState: "disconnected") == .wifi)
        #expect(PhysicalDevice.connection(pairingState: "paired", transportType: "localNetwork", tunnelState: "unavailable") == .offline)
        #expect(PhysicalDevice.connection(pairingState: "paired", transportType: nil, tunnelState: nil) == .offline)
        #expect(PhysicalDevice.connection(pairingState: "unpaired", transportType: "wired", tunnelState: "disconnected") == .notPaired)
        #expect(PhysicalDevice.Connection.usb.isReachable && PhysicalDevice.Connection.wifi.isReachable)
        #expect(!PhysicalDevice.Connection.offline.isReachable)
    }

    @Test func explainsAFailureWithItsRootCause() {
        #expect(throws: DeviceCtlError(
            command: "device info apps",
            message: "The developer disk image could not be mounted on this device. The device is locked."
        )) {
            try DeviceApp.parseList(Data(DeviceFixtures.lockedDevice.utf8))
        }
        #expect(DeviceCtlFailure.plainCause("Error mounting image: 0xe80000e2 (kAMDMobileImageMounterDeviceLocked: The device is locked.)") == "The device is locked.")
        #expect(DeviceCtlFailure.plainCause("Connection interrupted") == "Connection interrupted")
    }

    @Test func readsTheFirstErrorDevicectlPrinted() {
        let text = """
        ERROR: The developer disk image could not be mounted on this device. (com.apple.dt.CoreDeviceError error 12040 (0x2F08))
               DeviceIdentifier = 0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D
        """
        #expect(DeviceCtl.firstError(in: text) == "The developer disk image could not be mounted on this device. (com.apple.dt.CoreDeviceError error 12040 (0x2F08))")
        #expect(DeviceCtl.firstError(in: "") == "")
        #expect(DeviceCtlError(command: "list devices", message: "").localizedDescription == "devicectl list devices failed.")
    }
}

struct DeviceAppTests {
    @Test func listsYourOwnBuildsFirstAndLeavesOutAppClips() throws {
        let apps = try DeviceApp.parseList(Data(DeviceFixtures.apps.utf8))
        #expect(apps.map(\.bundleID) == ["com.example.demo", "com.example.store"])
        #expect(apps[0].isDeveloperBuild)
        #expect(apps[0].versionText == "Version 1.0 (7)")
        #expect(apps[1].url?.lastPathComponent == "Store App.app")
    }

    @Test func findsOnlyTheAppsOwnProcess() throws {
        let apps = try DeviceApp.parseList(Data(DeviceFixtures.apps.utf8))
        let processes = try DeviceProcess.parseList(Data(DeviceFixtures.processes.utf8))
        #expect(processes.count == 5)
        #expect(DeviceProcess.pids(of: try #require(apps[0].url), in: processes) == [412])
        #expect(DeviceProcess.pids(of: try #require(apps[1].url), in: processes) == [520])
        let withoutPrivate = try #require(URL(string: "file:///var/containers/Bundle/Application/9F2E1D0C-B3A4-4958-A6B7-C8D9E0F1A2B3/Demo.app"))
        #expect(DeviceProcess.pids(of: withoutPrivate, in: processes) == [412])
        #expect(DeviceProcess.pids(of: URL(filePath: "/var/containers/Bundle/Application/X/Other.app"), in: processes).isEmpty)
    }

    @Test func readsWhatWasInstalled() throws {
        struct Installed: Decodable {
            struct App: Decodable { let bundleID: String }
            let installedApplications: [App]
        }
        let result = try DeviceCtl.decode(Installed.self, from: Data(DeviceFixtures.install.utf8), command: "device install app")
        #expect(result.installedApplications.map(\.bundleID) == ["com.example.demo"])
    }
}

struct DeviceCommandTests {
    let device = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"

    @Test func buildsTheArgumentsForEachAction() {
        #expect(DeviceCommand.listDevices == ["list", "devices"])
        #expect(DeviceCommand.install(URL(filePath: "/tmp/Build/My App.ipa"), on: device)
            == ["device", "install", "app", "--device", device, "/tmp/Build/My App.ipa"])
        #expect(DeviceCommand.launch("com.example.demo", on: device)
            == ["device", "process", "launch", "--device", device, "com.example.demo"])
        #expect(DeviceCommand.launch("com.example.demo", on: device, payloadURL: "demo://items/42", terminatingExisting: true)
            == ["device", "process", "launch", "--device", device, "--terminate-existing", "--payload-url", "demo://items/42", "com.example.demo"])
        #expect(DeviceCommand.terminate(pid: 412, on: device) == ["device", "process", "terminate", "--device", device, "--pid", "412"])
        #expect(DeviceCommand.apps(on: device) == ["device", "info", "apps", "--device", device])
        #expect(DeviceCommand.apps(on: device, bundleID: "com.example.demo")
            == ["device", "info", "apps", "--device", device, "--bundle-id", "com.example.demo"])
        #expect(DeviceCommand.processes(on: device) == ["device", "info", "processes", "--device", device])
    }

    @Test func putsTheOutputOptionsBeforeTheSubcommand() {
        let launch = DeviceCommand.launch("com.example.demo", on: device, payloadURL: "demo://x")
        let json = URL(filePath: "/tmp/out.json")
        #expect(DeviceCtl.arguments(launch, jsonOutput: json, timeout: 60, viaXcrun: false)
            == ["--json-output", "/tmp/out.json", "--timeout", "60"] + launch)
        #expect(DeviceCtl.arguments(DeviceCommand.listDevices, jsonOutput: json, timeout: 15, viaXcrun: true)
            == ["devicectl", "--json-output", "/tmp/out.json", "--timeout", "15", "list", "devices"])
        #expect(DeviceCtl.name(of: launch) == "device process launch")
    }
}

struct DeviceChromeTests {
    let types: [SimulatorDeviceType]

    init() throws {
        types = try SimulatorDeviceType.parseList(Data(DeviceFixtures.deviceTypes.utf8))
    }

    @Test func matchesTheModelIdentifier() {
        #expect(SimulatorDeviceType.matching("iPhone17,1", model: "iPhone 16 Pro", in: types)?.name == "iPhone 16 Pro")
    }

    @Test func picksTheBaseModelOfMemoryVariants() {
        #expect(SimulatorDeviceType.matching("iPad17,4", model: "iPad Pro 13-inch (M5)", in: types)?.name == "iPad Pro 13-inch (M5)")
        #expect(SimulatorDeviceType.matching("iPad17,4", model: "iPad Pro (M5)", in: types)?.name == "iPad Pro 13-inch (M5)")
    }

    @Test func fallsBackToTheMarketingNameForWiFiOnlyIPads() {
        // The Simulator only knows the cellular iPad16,4; the Wi-Fi model is iPad16,3.
        #expect(SimulatorDeviceType.matching("iPad16,3", model: "iPad Pro 11-inch (M4)", in: types)?.identifier
            == "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-8GB")
    }

    @Test func givesUpOnModelsItDoesNotKnow() {
        #expect(SimulatorDeviceType.matching("iPhone99,9", model: "iPhone 99", in: types) == nil)
        #expect(SimulatorDeviceType.matching("", model: "", in: types) == nil)
    }

    @Test func borrowsTheSimulatorsBezelAndScreenShape() throws {
        let device = DeviceFixtures.device()
        let chrome = try #require(PhysicalDeviceChrome.load(for: device, types: types), "needs Xcode's iPhone 16 Pro device type")
        #expect(chrome.profile.hasChrome)
        #expect(chrome.profile.screenPixels == CGSize(width: 1206, height: 2622))
        let mask = try #require(chrome.screenMask)
        #expect(mask.path.hasPrefix(PhysicalDeviceChrome.maskFolder.path))
        #expect(FileManager.default.fileExists(atPath: mask.path))
    }

    @Test func putsAFrameFromTheDeviceInTheBezelWithRoundedCorners() throws {
        let chrome = try #require(PhysicalDeviceChrome.load(for: DeviceFixtures.device(), types: types))
        let profile = chrome.profile
        let frame = try #require(FramerTests.solidImage(width: 1206, height: 2622))
        let image = DeviceScreenshot.compose(frame, chrome: chrome, framed: true, style: Backdrop.Style())
        #expect(image.width == Int((profile.deviceSize.width * 3).rounded()))
        let pixels = try #require(FramerTests.rgba(image))
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y * image.width + x) * 4 ..< (y * image.width + x) * 4 + 4]) }
        #expect(pixel(image.width / 2, image.height / 2) == [255, 0, 0, 255])
        let screenLeft = Int(((profile.padding.left + profile.screenInset.width) * 3).rounded())
        let screenTop = Int(((profile.padding.top + profile.screenInset.height) * 3).rounded())
        #expect(pixel(screenLeft + 4, screenTop + 4) != [255, 0, 0, 255], "the screen's corner is cut away")

        let unframed = DeviceScreenshot.compose(frame, chrome: chrome, framed: false, style: Backdrop.Style())
        #expect(unframed.width == 1206 && unframed.height == 2622)
        let landscape = try #require(FramerTests.solidImage(width: 2622, height: 1206))
        #expect(DeviceScreenshot.compose(landscape, chrome: chrome, framed: true, style: Backdrop.Style()).width == 2622)
    }

    @Test func savesScreenshotsNamedAfterTheDevice() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = try #require(FramerTests.solidImage(width: 120, height: 260))
        let url = try DeviceScreenshot.save(frame, deviceName: "Test iPhone", chrome: nil, framed: true, style: Backdrop.Style(), folder: folder)
        #expect(url.lastPathComponent.hasPrefix("Test iPhone "))
        #expect(ImageFile.load(url)?.width == 120)
    }
}

struct MirrorTests {
    @Test func recognisesTheDevicesScreenAmongCaptureDevices() {
        let device = DeviceFixtures.device()
        #expect(ScreenCaptureDevices.isScreen(uniqueID: "00008140001A2B3C4D5E801E", name: "iPhone", of: device))
        #expect(ScreenCaptureDevices.isScreen(uniqueID: "00008140-001a2b3c4d5e801e", name: "iPhone", of: device))
        #expect(ScreenCaptureDevices.isScreen(uniqueID: "something-else", name: "Test iPhone", of: device))
        #expect(!ScreenCaptureDevices.isScreen(uniqueID: "something-else", name: "Test iPhone Camera", of: device))
        #expect(!ScreenCaptureDevices.isScreen(uniqueID: "", name: "FaceTime HD Camera", of: DeviceFixtures.device(udid: nil)))
    }

    @Test func shapesTheWindowLikeTheScreen() {
        let portrait = MirrorLayout.contentSize(for: CGSize(width: 1206, height: 2622), in: CGSize(width: 1440, height: 900))
        #expect(portrait.height == 765)
        #expect(abs(portrait.width / portrait.height - 1206 / 2622) < 0.005)
        let landscape = MirrorLayout.contentSize(for: CGSize(width: 2622, height: 1206), in: CGSize(width: 1440, height: 900))
        #expect(landscape.width == 1224)
        #expect(MirrorLayout.contentSize(for: .zero, in: CGSize(width: 1440, height: 900)) == CGSize(width: 360, height: 780))
    }
}
