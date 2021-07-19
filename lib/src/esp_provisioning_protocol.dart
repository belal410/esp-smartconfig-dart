import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:esp_smartconfig/src/esp_provisioning_request.dart';
import 'package:esp_smartconfig/src/esp_provisioning_response.dart';
import 'package:loggerx/loggerx.dart';

/// Abstract SmartConfig protocol
abstract class EspProvisioningProtocol {
  /// Network broadcast address
  static final broadcastAddress =
      InternetAddress.fromRawAddress(Uint8List.fromList([255, 255, 255, 255]));

  /// UDP port of Esp device
  static final devicePort = 7001;

  /// UDP socket used for sending and receiving packets
  late final RawDatagramSocket _socket;

  /// Index of protocol port
  late final int portIndex;

  /// Provisioning request
  late final EspProvisioningRequest request;

  /// Logger
  late final Logger logger;

  /// List of the protocol [ports].
  /// Provisioner will take one port after the another and try to open it.
  /// After first successfully opened port provisioner will stop and set
  /// the [portIndex] of opened port
  List<int> get ports;

  /// Protocol setup.
  /// Prepare package, set variables, etc...
  void setup(RawDatagramSocket socket, int portIndex,
      EspProvisioningRequest request, Logger logger) {
    _socket = socket;
    this.portIndex = portIndex;
    this.request = request;
    this.logger = logger;
  }

  /// Loop is invoked by provisioner [timer] in very short [stepMs] intervals, typically 1-10 ms.
  /// This is good place to send data
  void loop(int stepMs, Timer timer);

  /// Sends a data [buffer]
  int send(List<int> buffer) {
    return _socket.send(buffer, broadcastAddress, devicePort);
  }

  /// Receive data
  EspProvisioningResponse receive(Uint8List data);
}