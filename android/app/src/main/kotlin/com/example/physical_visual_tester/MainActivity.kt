package com.example.physical_visual_tester

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHidDevice
import android.bluetooth.BluetoothHidDeviceAppQosSettings
import android.bluetooth.BluetoothHidDeviceAppSdpSettings
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity() {
	private val channelName = "pvt/hid"

	private val permissionRequestCode = 4242

	private var bluetoothManager: BluetoothManager? = null
	private var bluetoothAdapter: BluetoothAdapter? = null
	private var hidDevice: BluetoothHidDevice? = null
	private var connectedHost: BluetoothDevice? = null

	private var appRegistered: Boolean = false
	private var advertising: Boolean = false
	private var lastEvent: String? = null
	private var lastError: String? = null
	private val eventLog: ArrayDeque<String> = ArrayDeque()
	private var originalAdapterName: String? = null

	private fun logEvent(msg: String) {
		lastEvent = msg
		val line = "${System.currentTimeMillis()}: $msg"
		eventLog.addFirst(line)
		while (eventLog.size > 50) eventLog.removeLast()
        android.util.Log.d("PVT_DEBUG", msg)
	}

	private fun logError(msg: String?) {
		lastError = msg
		if (msg != null) logEvent("ERROR: $msg")
	}

	private val hidServiceUuid: ParcelUuid = ParcelUuid(
		UUID.fromString("00001812-0000-1000-8000-00805f9b34fb")
	)

	private val serviceListener = object : BluetoothProfile.ServiceListener {
		override fun onServiceConnected(profile: Int, proxy: BluetoothProfile?) {
			if (profile != BluetoothProfile.HID_DEVICE) return
			hidDevice = proxy as BluetoothHidDevice
			logEvent("HID_DEVICE proxy connected")
            // Auto-start if permissions are already granted to reduce friction
            if (checkPermissionsGranted()) {
                try {
                    startHidKeyboard()
                    logEvent("Auto-started HID keyboard")
                } catch (e: Exception) {
                    logError("Auto-start failed: ${e.message}")
                }
            }
		}

		override fun onServiceDisconnected(profile: Int) {
			if (profile != BluetoothProfile.HID_DEVICE) return
			hidDevice = null
			appRegistered = false
			connectedHost = null
			logEvent("HID_DEVICE proxy disconnected")
		}
	}

    private fun checkPermissionsGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val connect = ContextCompat.checkSelfPermission(this@MainActivity, android.Manifest.permission.BLUETOOTH_CONNECT)
        val advertise = ContextCompat.checkSelfPermission(this@MainActivity, android.Manifest.permission.BLUETOOTH_ADVERTISE)
        return connect == PackageManager.PERMISSION_GRANTED && advertise == PackageManager.PERMISSION_GRANTED
    }

	private val hidCallback = object : BluetoothHidDevice.Callback() {
		override fun onAppStatusChanged(pluggedDevice: BluetoothDevice?, registered: Boolean) {
			appRegistered = registered
			logEvent("onAppStatusChanged registered=$registered")
		}

		override fun onConnectionStateChanged(device: BluetoothDevice?, state: Int) {
			logEvent("onConnectionStateChanged state=$state device=${device?.address}")
			if (state == BluetoothProfile.STATE_CONNECTED) {
				connectedHost = device
			} else if (state == BluetoothProfile.STATE_DISCONNECTED) {
                // If it was the connected host, clear it.
				if (connectedHost?.address == device?.address) {
					connectedHost = null
				}
			} else if (state == BluetoothProfile.STATE_CONNECTING) {
                // IMPORTANT: When a host connects, we must ensure the policy is allowed.
                // ALSO: Some stacks require us to actively 'connect' back to accept/finalize.
                if (device != null && hidDevice != null) {
                    val pol = tryAllowConnectionPolicy(this@MainActivity.hidDevice!!, device)
                    logEvent("Policy allowed: $pol")
                    // Initiating a connect() here acts as an acceptance in some Android versions
                    val ok = hidDevice?.connect(device) ?: false
                    logEvent("hid.connect() called in CONNECTING: $ok")
                }
            }
		}

		override fun onGetReport(
			device: BluetoothDevice?,
			type: Byte,
			id: Byte,
			bufferSize: Int
		) {
			logEvent("onGetReport type=$type id=$id")
            val hid = hidDevice ?: return
            if (device == null) return
            // Respond with "Invalid Request" or "Not Ready" usually, or just an empty report if matching.
            // For now, sending a Handbook-compliant 'Handshake' error or simple reply is safer than silence.
            // But API requires replyReport(device, type, id, data).
            // We'll send an empty successful report for ID 1 (keyboard) if requested, else error.
            if (id.toInt() == 1) {
                 hid.replyReport(device, type, id, byteArrayOf(0, 0, 0, 0, 0, 0, 0, 0))
            } else {
                 // Indicate unsupported request.
                 hid.reportError(device, BluetoothHidDevice.ERROR_RSP_INVALID_RPT_ID)
            }
		}

		override fun onSetReport(device: BluetoothDevice?, type: Byte, id: Byte, data: ByteArray?) {
			logEvent("onSetReport type=$type id=$id")
             val hid = hidDevice ?: return
             if (device == null) return
             // Acknowledge the set report (e.g. Caps Lock LED).
             hid.replyReport(device, type, id, byteArrayOf())
		}
        
        override fun onSetProtocol(device: BluetoothDevice?, protocol: Byte) {
            logEvent("onSetProtocol protocol=$protocol")
            // Windows often sets protocol 0 (Boot) or 1 (Report).
            // We should imply success. Standard HID says we don't need to reply,
            // but if we did, there's no replyProtocol API.
        }

        override fun onInterruptData(device: BluetoothDevice?, reportId: Byte, data: ByteArray?) {
             // Host sent data on interrupt channel (e.g. Output report)
             logEvent("onInterruptData id=$reportId")
        }
	}

	private val advertiseCallback = object : AdvertiseCallback() {
		override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
			advertising = true
			logEvent("onStartSuccess advertising=true")
		}

		override fun onStartFailure(errorCode: Int) {
			advertising = false
			logEvent("onStartFailure advertising=false code=$errorCode")
			logError("Advertise start failed code=$errorCode")
		}
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
        
        // Register receivers
        val filter = android.content.IntentFilter()
        filter.addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        filter.addAction(BluetoothDevice.ACTION_PAIRING_REQUEST)
        try {
            registerReceiver(bondStateReceiver, filter)
        } catch(e: Exception) {
            logError("Receiver reg failed: ${e.message}")
        }

		bluetoothManager = getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
		bluetoothAdapter = bluetoothManager?.adapter

		// Ensure profile proxy is requested early.
		bluetoothAdapter?.getProfileProxy(this, serviceListener, BluetoothProfile.HID_DEVICE)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
			.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
				when (call.method) {
					"getEventLog" -> {
						result.success(eventLog.toList())
					}
					"getLocalName" -> {
						val adapter = bluetoothAdapter
						result.success(adapter?.name)
					}
					"setLocalName" -> {
						val args = call.arguments as? Map<*, *>
						val name = args?.get("name") as? String
						if (name == null || name.isBlank()) {
							result.error("BAD_ARGS", "Missing 'name'", null)
							return@setMethodCallHandler
						}
						try {
							setLocalAdapterName(name)
							result.success(null)
						} catch (e: SecurityException) {
							logError(e.message)
							result.error("PERMISSION", e.message, null)
						} catch (e: Exception) {
							logError(e.message)
							result.error("NAME_FAILED", e.message, null)
						}
					}
					"requestPermissions" -> {
						try {
							requestBluetoothPermissionsIfNeeded()
							result.success(null)
						} catch (e: Exception) {
							logError(e.message)
							result.error("PERMISSION_REQUEST_FAILED", e.message, null)
						}
					}
					"requestDiscoverable" -> {
						try {
							requestDiscoverable()
							result.success(null)
						} catch (e: Exception) {
							logError(e.message)
							result.error("DISCOVERABLE_FAILED", e.message, null)
						}
					}
					"connect" -> {
						try {
							startHidKeyboard()
							result.success(null)
						} catch (e: SecurityException) {
							logError(e.message)
							result.error("PERMISSION", e.message, null)
						} catch (e: Exception) {
							logError(e.message)
							result.error("START_FAILED", e.message, null)
						}
					}
					"disconnect" -> {
						try {
							stopHidKeyboard()
							result.success(null)
						} catch (e: SecurityException) {
							logError(e.message)
							result.error("PERMISSION", e.message, null)
						} catch (e: Exception) {
							logError(e.message)
							result.error("STOP_FAILED", e.message, null)
						}
					}
					"listBondedDevices" -> {
						try {
							val adapter = bluetoothAdapter
							if (adapter == null) {
								result.success(emptyList<Map<String, Any?>>())
								return@setMethodCallHandler
							}
							val bonded = adapter.bondedDevices
							val list = bonded.map { d ->
								val state = try {
									hidDevice?.getConnectionState(d)
								} catch (_: Exception) {
									null
								}
								mapOf(
									"name" to d.name,
									"address" to d.address,
									"type" to d.type,
									"bondState" to d.bondState,
									"hidConnectionState" to state,
								)
							}
							result.success(list)
						} catch (e: SecurityException) {
							logError(e.message)
							result.error("PERMISSION", e.message, null)
						} catch (e: Exception) {
							logError(e.message)
							result.error("LIST_FAILED", e.message, null)
						}
					}
					"connectHost" -> {
						val args = call.arguments as? Map<*, *>
						val address = args?.get("address") as? String
						if (address == null) {
							result.error("BAD_ARGS", "Missing 'address'", null)
							return@setMethodCallHandler
						}
						try {
							connectToHost(address)
							result.success(null)
						} catch (e: SecurityException) {
							logError(e.message)
							result.error("PERMISSION", e.message, null)
						} catch (e: Exception) {
							logError(e.message)
							result.error("CONNECT_FAILED", e.message, null)
						}
					}
					"disconnectHost" -> {
						try {
							disconnectHost()
							result.success(null)
						} catch (e: SecurityException) {
							logError(e.message)
							result.error("PERMISSION", e.message, null)
						} catch (e: Exception) {
							logError(e.message)
							result.error("DISCONNECT_FAILED", e.message, null)
						}
					}
                    "unbondDevice" -> {
						val args = call.arguments as? Map<*, *>
						val address = args?.get("address") as? String
						if (address == null) {
							result.error("BAD_ARGS", "Missing 'address'", null)
							return@setMethodCallHandler
						}
                        try {
                            val adapter = bluetoothAdapter
                            val device = adapter?.getRemoteDevice(address)
                            if (device != null) {
                                removeBond(device)
                                result.success(null)
                            } else {
                                result.error("NOT_FOUND", "Device not found", null)
                            }
                        } catch(e: Exception) {
                            logError("unbond failed: $e")
                            result.error("UNBOND_FAILED", e.message, null)
                        }
                    }
					"getDebugState" -> {
						val adapter = bluetoothAdapter
						val host = connectedHost
						val advertiserAvailable = try {
							adapter?.bluetoothLeAdvertiser != null
						} catch (_: SecurityException) {
							false
						}
						val bondedCount = try {
							adapter?.bondedDevices?.size ?: 0
						} catch (_: SecurityException) {
							-1
						}
						result.success(
							mapOf(
								"adapterEnabled" to (adapter?.isEnabled == true),
								"adapterName" to adapter?.name,
								"scanMode" to adapter?.scanMode,
								"leAdvertiserAvailable" to advertiserAvailable,
								"hidReady" to (hidDevice != null),
								"appRegistered" to appRegistered,
								"advertising" to advertising,
								"connectedHostName" to host?.name,
								"connectedHostAddress" to host?.address,
								"bondedCount" to bondedCount,
								"lastEvent" to lastEvent,
								"lastError" to lastError,
							)
						)
					}
					"sendKeyText" -> {
						val args = call.arguments as? Map<*, *>
						val text = args?.get("text") as? String
						if (text == null) {
							result.error("BAD_ARGS", "Missing 'text'", null)
							return@setMethodCallHandler
						}
						try {
							sendKeyText(text)
							result.success(null)
						} catch (e: SecurityException) {
							logError(e.message)
							result.error("PERMISSION", e.message, null)
						} catch (e: Exception) {
							logError(e.message)
							result.error("SEND_FAILED", e.message, null)
						}
					}
					"sendMouseMove" -> {
						val args = call.arguments as? Map<*, *>
						val dx = (args?.get("dx") as? Int) ?: 0
						val dy = (args?.get("dy") as? Int) ?: 0
						try {
							sendMouseMove(dx, dy)
							result.success(null)
						} catch (e: Exception) {
							logError(e.message)
							result.error("MOUSE_FAILED", e.message, null)
						}
					}
					"sendClick" -> {
                        val args = call.arguments as? Map<*, *>
                        val button = (args?.get("button") as? Int) ?: 1
						try {
							sendMouseClick(button)
							result.success(null)
						} catch (e: Exception) {
							logError(e.message)
							result.error("CLICK_FAILED", e.message, null)
						}
					}
                    "sendLongPress" -> {
                        val args = call.arguments as? Map<*, *>
                        val duration = (args?.get("duration") as? Int)?.toLong() ?: 1000L
                        val button = (args?.get("button") as? Int) ?: 1
                        try {
                            sendMouseLongPress(button, duration)
                            result.success(null)
                        } catch (e: Exception) {
                            logError(e.message)
                            result.error("LONG_PRESS_FAILED", e.message, null)
                        }
                    }
					"getState" -> {
						val host = connectedHost
						result.success(
							mapOf(
								"connected" to (host != null),
								"deviceName" to (host?.name)
							)
						)
					}
					"openAppSettings" -> {
						try {
							val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
							intent.data = android.net.Uri.fromParts("package", packageName, null)
							startActivity(intent)
							result.success(null)
						} catch (e: Exception) {
							logError("Failed to open settings: ${e.message}")
							result.error("SETTINGS_FAILED", e.message, null)
						}
					}
					else -> result.notImplemented()
				}
			}
	}

	private fun requestBluetoothPermissionsIfNeeded() {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return

		val needed = mutableListOf<String>()
		val perms = arrayOf(
			android.Manifest.permission.BLUETOOTH_CONNECT,
			android.Manifest.permission.BLUETOOTH_ADVERTISE,
			android.Manifest.permission.BLUETOOTH_SCAN,
		)
		for (p in perms) {
			if (ContextCompat.checkSelfPermission(this, p) != PackageManager.PERMISSION_GRANTED) {
				needed.add(p)
			}
		}

		if (needed.isNotEmpty()) {
			ActivityCompat.requestPermissions(this, needed.toTypedArray(), permissionRequestCode)
		}
	}

	private fun requestDiscoverable() {
		val adapter = bluetoothAdapter ?: throw IllegalStateException("Bluetooth not available")
		if (!adapter.isEnabled) throw IllegalStateException("Bluetooth is disabled")

		val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE)
		intent.putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 300)
		startActivity(intent)
		logEvent("requestDiscoverable launched")
	}

	private fun setLocalAdapterName(name: String) {
		val adapter = bluetoothAdapter ?: throw IllegalStateException("Bluetooth not available")
		if (originalAdapterName == null) originalAdapterName = adapter.name
		val ok = adapter.setName(name)
		if (!ok) throw IllegalStateException("setName returned false")
		logEvent("setLocalAdapterName name=$name")
	}

	private fun connectToHost(address: String) {
		startHidKeyboard()
		val hid = hidDevice ?: throw IllegalStateException("HID profile not ready")
		val adapter = bluetoothAdapter ?: throw IllegalStateException("Bluetooth not available")
		val device = try {
			adapter.getRemoteDevice(address)
		} catch (e: IllegalArgumentException) {
			throw IllegalStateException("Invalid device address")
		}
		// Some stacks require allowing the connection policy first.
		// These APIs are not consistently available in the public Android SDK, so use reflection best-effort.
		tryAllowConnectionPolicy(hid, device)
		val ok = hid.connect(device)
		if (!ok) {
			throw IllegalStateException("hid.connect returned false")
		}
		logEvent("connectToHost address=$address")
	}

	private fun tryAllowConnectionPolicy(profile: Any, device: BluetoothDevice): Boolean {
		try {
			val allowedPolicy = 100
			val method = profile.javaClass.methods.firstOrNull { m ->
				m.name == "setConnectionPolicy" &&
					m.parameterTypes.size == 2 &&
					m.parameterTypes[0] == BluetoothDevice::class.java &&
					(m.parameterTypes[1] == Int::class.javaPrimitiveType || m.parameterTypes[1] == Integer::class.java)
			}
            if (method != null) {
			    method.invoke(profile, device, allowedPolicy)
                return true
            } else {
                // logError("setConnectionPolicy method not found")
            }
        } catch (e: java.lang.reflect.InvocationTargetException) {
            val cause = e.targetException
            if (cause is SecurityException) {
                // Expected on Android 12+/Pixel if not system app. Suppress noise.
                return false
            }
            logError("Policy set failed (InvocationTargetException): ${cause?.message}")
        } catch (e: SecurityException) {
            // Expected
		} catch (e: Throwable) {
			logError("Policy set failed: $e")
		}
        return false
	}
    
    private fun removeBond(device: BluetoothDevice) {
        try {
            val method = device.javaClass.getMethod("removeBond")
            method.invoke(device)
            logEvent("Removed bond for ${device.address}")
        } catch (e: Exception) {
            logError("removeBond failed: $e")
        }
    }

	private fun disconnectHost() {
		val hid = hidDevice ?: throw IllegalStateException("HID profile not ready")
		val host = connectedHost ?: return
		hid.disconnect(host)
		logEvent("disconnectHost address=${host.address}")
	}

	private val bondStateReceiver = object : android.content.BroadcastReceiver() {
		override fun onReceive(context: android.content.Context, intent: Intent) {
			val action = intent.action
			val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
			if (BluetoothDevice.ACTION_BOND_STATE_CHANGED == action) {
				val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
				val previous = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.ERROR)
                val stateStr = when(state) {
                    BluetoothDevice.BOND_NONE -> "NONE"
                    BluetoothDevice.BOND_BONDING -> "BONDING"
                    BluetoothDevice.BOND_BONDED -> "BONDED"
                    else -> "UNKNOWN($state)"
                }
				logEvent("BOND_STATE_CHANGED: $stateStr (prev=$previous) device=${device?.address}")
                
                // If we just bonded, ensure policy is allowed immediately
                if (state == BluetoothDevice.BOND_BONDED && device != null && hidDevice != null) {
                     val ok = tryAllowConnectionPolicy(hidDevice!!, device)
                     logEvent("Policy allowed for new bond: $ok")
                     // Try active connect again just in case
                     hidDevice?.connect(device)
                }
			} else if (BluetoothDevice.ACTION_PAIRING_REQUEST == action) {
                // This intent is usually just a notification, we can't interact with it, but good to know it fired.
                logEvent("ACTION_PAIRING_REQUEST received for ${device?.address}")
            }
		}
	}

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(bondStateReceiver)
        } catch(e: Exception) {}
    }

	private fun startHidKeyboard() {
		val adapter = bluetoothAdapter ?: throw IllegalStateException("Bluetooth not available")
		if (!adapter.isEnabled) {
			throw IllegalStateException("Bluetooth is disabled")
		}

		val hid = hidDevice
			?: throw IllegalStateException("HID device profile not ready yet")

		if (!appRegistered) {
			val sdp = BluetoothHidDeviceAppSdpSettings(
				"PVT HID",
				"PVT Keyboard Spike",
				"PVT",
				BluetoothHidDevice.SUBCLASS1_KEYBOARD,
				keyboardReportDescriptor()
			)

			// Reverting QoS to null as explicit values caused registerApp failure on Pixel 9.
			val qos: BluetoothHidDeviceAppQosSettings? = null
            
			val executor = ContextCompat.getMainExecutor(this)
			val ok = hid.registerApp(sdp, null, qos, executor, hidCallback)
			if (!ok) {
				throw IllegalStateException("registerApp returned false")
			}
		}

        // Proactively allow policy for all bonded devices to be safe
        allowPolicyForBondedDevices()

		startAdvertising()
        
        // Auto-connect to bonded host (e.g. Laptop)
        connectToBondedDevices()
	}

    private fun allowPolicyForBondedDevices() {
        try {
            val bonded = bluetoothAdapter?.bondedDevices
            if (bonded.isNullOrEmpty()) return
            val hid = hidDevice ?: return
            for (curr in bonded) {
               tryAllowConnectionPolicy(hid, curr)
            }
            logEvent("Allowed policy for ${bonded.size} bonded devices")
        } catch(e: Exception) {
            logError("Failed to allow bulk policy: ${e.message}")
        }
    }

    private fun connectToBondedDevices() {
        val hid = hidDevice ?: return
        val adapter = bluetoothAdapter ?: return
        val bonded = adapter.bondedDevices
        if (bonded.isNullOrEmpty()) {
            logEvent("No bonded devices to connect to.")
            return
        }

        // iterate and try to connect
        for (device in bonded) {
            // We can't easily distinguish 'Laptop' from 'Headphones' just by bond without digging into BluetoothClass,
            // but for a HID peripheral, trying to connect to a bonded device is generally safe.
            // The first one that accepts our L2CAP usage will succeed.
            logEvent("Attempting auto-connect to ${device.name} (${device.address})")
            
            // Ensure policy is allowed first
            tryAllowConnectionPolicy(hid, device)
            
            try {
                hid.connect(device)
            } catch (e: Exception) {
                logError("Failed to connect to ${device.address}: ${e.message}")
            }
        }
    }

	private fun stopHidKeyboard() {
		stopAdvertising()
		hidDevice?.unregisterApp()
		appRegistered = false
		connectedHost = null
	}

	private fun startAdvertising() {
        // We are using Bluetooth Classic HID (BluetoothHidDevice).
        // Advertising BLE HID Service (0x1812) without a matching GATT server (HOGP) 
        // confuses some hosts (like Windows) which try to connect via BLE and fail.
        // We relying on Classic Discovery (requestDiscoverable) instead.
		/*
		val adapter = bluetoothAdapter ?: return
		val advertiser = adapter.bluetoothLeAdvertiser ?: return

		if (advertising) return

		val settings = AdvertiseSettings.Builder()
			.setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
			.setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
			.setConnectable(true)
			.build()

		val data = AdvertiseData.Builder()
			.setIncludeDeviceName(false)
			.addServiceUuid(hidServiceUuid)
			.build()

		val scanResponse = AdvertiseData.Builder()
			.setIncludeDeviceName(true)
			.build()

		advertiser.startAdvertising(settings, data, scanResponse, advertiseCallback)
		*/
	}

	private fun stopAdvertising() {
		/*
		val adapter = bluetoothAdapter ?: return
		val advertiser = adapter.bluetoothLeAdvertiser ?: return

		if (!advertising) return
		advertiser.stopAdvertising(advertiseCallback)
		advertising = false
		*/
	}

	private fun sendKeyText(text: String) {
        // Robustness: Verify 'connectedHost' is actually connected.
        var host = connectedHost
        val hid = hidDevice ?: throw IllegalStateException("HID profile not ready")
        
        if (host != null) {
            val state = try {
                hid.getConnectionState(host)
            } catch (e: Exception) {
                BluetoothProfile.STATE_DISCONNECTED
            }
            if (state != BluetoothProfile.STATE_CONNECTED) {
                logEvent("Host ${host.address} state=$state. Clearing connectedHost.")
                host = null
                connectedHost = null
            }
        }

        // If we don't have a valid host, try to recover one
        if (host == null) {
            val validHost = bluetoothAdapter?.bondedDevices?.firstOrNull { d ->
                try {
                    hid.getConnectionState(d) == BluetoothProfile.STATE_CONNECTED
                } catch (e: Exception) { false }
            }
            if (validHost != null) {
                connectedHost = validHost
                host = validHost
                logEvent("Recovered connection to ${validHost.name}")
            }
        }

		val targetHost = host ?: throw IllegalStateException(
			"Not connected to a host. Pair/connect from the PC first."
		)

		for (ch in text.toCharArray()) {
			val mapping = mapCharToKey(ch)
				?: continue
			val modifier = mapping.first
			val keyCode = mapping.second

			// Press
			val press = byteArrayOf(
				modifier.toByte(),
				0x00,
				keyCode.toByte(),
				0x00,
				0x00,
				0x00,
				0x00,
				0x00
			)
			val okPress = hid.sendReport(targetHost, 1, press)
            if (!okPress) logEvent("sendReport(press) failed")

			// Release
			val release = byteArrayOf(0, 0, 0, 0, 0, 0, 0, 0)
			val okRelease = hid.sendReport(targetHost, 1, release)
            if (!okRelease) logEvent("sendReport(release) failed")
		}
	}

	private fun mapCharToKey(ch: Char): Pair<Int, Int>? {
		// Modifier bit 1 = Left Shift
		val SHIFT = 0x02

		if (ch in 'a'..'z') {
			val code = 0x04 + (ch.code - 'a'.code)
			return Pair(0, code)
		}
		if (ch in 'A'..'Z') {
			val code = 0x04 + (ch.code - 'A'.code)
			return Pair(SHIFT, code)
		}
		if (ch in '1'..'9') {
			val code = 0x1E + (ch.code - '1'.code)
			return Pair(0, code)
		}
		if (ch == '0') {
			return Pair(0, 0x27)
		}
		return when (ch) {
			' ' -> Pair(0, 0x2C)
			'\n' -> Pair(0, 0x28)
			'\r' -> Pair(0, 0x28)
			'.' -> Pair(0, 0x37)
			',' -> Pair(0, 0x36)
			'-' -> Pair(0, 0x2D)
			'_' -> Pair(SHIFT, 0x2D)
			else -> null
		}
	}

    private fun sendMouseMove(dx: Int, dy: Int) {
        val hid = ensureConnected() ?: return
        val host = connectedHost!!
        
        // Report ID 2: [Buttons, X, Y]
        // Buttons = 0 (no click)
        // X, Y are signed bytes (-127 to 127). Clamp them.
        val x = dx.coerceIn(-127, 127).toByte()
        val y = dy.coerceIn(-127, 127).toByte()
        
        val report = byteArrayOf(0, x, y)
        val ok = hid.sendReport(host, 2, report)
        if (!ok) logEvent("sendMouseMove failed")
    }

    private fun sendMouseClick(buttonId: Int) {
        val hid = ensureConnected() ?: return
        val host = connectedHost!!
        
        val btnByte = getButtonByte(buttonId)
        
        // Down
        hid.sendReport(host, 2, byteArrayOf(btnByte, 0, 0))
        // Up
        hid.sendReport(host, 2, byteArrayOf(0, 0, 0))
    }
    
    private fun sendMouseLongPress(buttonId: Int, durationMs: Long) {
        val hid = ensureConnected() ?: return
        val host = connectedHost!!
        val btnByte = getButtonByte(buttonId)
        
        // Down
        hid.sendReport(host, 2, byteArrayOf(btnByte, 0, 0))
        
        // Delay Up
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            try {
                 // We don't want to re-check ensureConnected here as it might thread-block or be stale, 
                 // but we need 'hid' and 'host'. If disconnected in meantime, this throws/fails safely.
                 hid.sendReport(host, 2, byteArrayOf(0, 0, 0))
            } catch (e: Exception) {
                logError("Failed to release long press: ${e.message}")
            }
        }, durationMs)
    }
    
    private fun getButtonByte(id: Int): Byte {
        return when(id) {
            1 -> 1 // Left (0x01)
            2 -> 2 // Right (0x02)
            3 -> 4 // Middle (0x04)
            else -> 1
        }.toByte()
    }
    
    private fun ensureConnected(): BluetoothHidDevice? {
        val hid = hidDevice
         if (hid == null) {
             logError("HID profile not ready")
             return null
         }
         
         // Verify existing host is still valid
         var host = connectedHost
         if (host != null) {
            val state = try {
                hid.getConnectionState(host)
            } catch (e: Exception) { BluetoothProfile.STATE_DISCONNECTED }
            
            if (state != BluetoothProfile.STATE_CONNECTED) {
                host = null
                connectedHost = null
            }
         }

         if (host == null) {
             // Try recovery
             val bonded = bluetoothAdapter?.bondedDevices
             if (!bonded.isNullOrEmpty()) {
                 val hid = hidDevice!!
                 // Try to find one that IS connected first
                 var validHost = bonded.firstOrNull { d ->
                    try {
                        hid.getConnectionState(d) == BluetoothProfile.STATE_CONNECTED
                    } catch (e: Exception) { false }
                }
                
                // If none connected, try to CONNECT to the first one (Active Reconnection)
                if (validHost == null) {
                    val candidate = bonded.first() // Simply pick the first one for now
                    logEvent("No active host. Attempting to force connect to ${candidate.name}")
                    tryAllowConnectionPolicy(hid, candidate)
                    hid.connect(candidate)
                    // We can't wait for the result here synchronously as it's async. 
                    // We just initiate and hope the user retries or it connects fast enough.
                    // But for this call, we technically fail until the callback fires.
                    throw IllegalStateException("Reconnecting to ${candidate.name}... Please try again in a moment.")
                }

                if (validHost != null) {
                    connectedHost = validHost
                    logEvent("Recovered connection (Mouse)")
                } else {
                    throw IllegalStateException("Not connected to host")
                }
             } else {
                 throw IllegalStateException("No bonded devices found")
             }
         }
         return hid
    }

	private fun keyboardReportDescriptor(): ByteArray {
		// Composite Report Descriptor: Keyboard (ID 1) + Mouse (ID 2)
		return byteArrayOf(
            // Keyboard (ID 1)
			0x05, 0x01, // Usage Page (Generic Desktop)
			0x09, 0x06, // Usage (Keyboard)
			0xA1.toByte(), 0x01, // Collection (Application)
			0x85.toByte(), 0x01, //   Report ID (1)
			0x05, 0x07, //   Usage Page (Key Codes)
			0x19, 0xE0.toByte(), //   Usage Minimum (224)
			0x29, 0xE7.toByte(), //   Usage Maximum (231)
			0x15, 0x00, //   Logical Minimum (0)
			0x25, 0x01, //   Logical Maximum (1)
			0x75, 0x01, //   Report Size (1)
			0x95.toByte(), 0x08, //   Report Count (8)
			0x81.toByte(), 0x02, //   Input (Data, Variable, Absolute) ; Modifier
			0x95.toByte(), 0x01, //   Report Count (1)
			0x75, 0x08, //   Report Size (8)
			0x81.toByte(), 0x03, //   Input (Constant) ; Reserved
			0x95.toByte(), 0x06, //   Report Count (6)
			0x75, 0x08, //   Report Size (8)
			0x15, 0x00, //   Logical Minimum (0)
			0x25, 0x65, //   Logical Maximum (101)
			0x05, 0x07, //   Usage Page (Key Codes)
			0x19, 0x00, //   Usage Minimum (0)
			0x29, 0x65, //   Usage Maximum (101)
			0x81.toByte(), 0x00, //   Input (Data, Array)
			0xC0.toByte(), // End Collection

            // Mouse (ID 2)
            0x05, 0x01,        // Usage Page (Generic Desktop)
            0x09, 0x02,        // Usage (Mouse)
            0xA1.toByte(), 0x01, // Collection (Application)
            0x85.toByte(), 0x02, //   Report ID (2)
            0x09, 0x01,        //   Usage (Pointer)
            0xA1.toByte(), 0x00, //   Collection (Physical)
            0x05, 0x09,        //     Usage Page (Button)
            0x19, 0x01,        //     Usage Minimum (1)
            0x29, 0x03,        //     Usage Maximum (3)
            0x15, 0x00,        //     Logical Minimum (0)
            0x25, 0x01,        //     Logical Maximum (1)
            0x95.toByte(), 0x03, //     Report Count (3)
            0x75, 0x01,        //     Report Size (1)
            0x81.toByte(), 0x02, //     Input (Data, Variable, Absolute)
            0x95.toByte(), 0x01, //     Report Count (1)
            0x75, 0x05,        //     Report Size (5) - Padding
            0x81.toByte(), 0x03, //     Input (Constant)
            0x05, 0x01,        //     Usage Page (Generic Desktop)
            0x09, 0x30,        //     Usage (X)
            0x09, 0x31,        //     Usage (Y)
            0x15, 0x81.toByte(), //     Logical Minimum (-127)
            0x25, 0x7F,        //     Logical Maximum (127)
            0x75, 0x08,        //     Report Size (8)
            0x95.toByte(), 0x02, //     Report Count (2)
            0x81.toByte(), 0x06, //     Input (Data, Variable, Relative)
            0xC0.toByte(),       //   End Collection
            0xC0.toByte()        // End Collection
		)
	}
}
