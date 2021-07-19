import 'dart:typed_data';

import 'package:esp_smartconfig/esp_smartconfig.dart';
import 'package:esp_smartconfig/src/esp_provisioner.dart';
import 'package:esp_smartconfig/src/esp_provisioning_crc.dart';
import 'package:loggerx/loggerx.dart';

class EspProvisioningPackage {
  late Logger _logger;
  final EspProvisioningRequest request;
  final int portIndex;

  late Int8List _buffer;

  final _blocks = <Int8List>[];

  List<Int8List> get blocks => _blocks;

  var _isSsidEncoded = false;
  var _isPasswordEncoded = false;
  var _isReservedDataEncoded = false;

  int _ssidPaddingFactor = 6;
  int _passwordPaddingFactor = 6;
  int _reservedPaddingFactor = 6;

  bool get isSsidEncoded => _isSsidEncoded;
  bool get isPasswordEncoded => _isPasswordEncoded;
  bool get isReservedDataEncoded => _isReservedDataEncoded;

  int _headLength = 0;
  int _passwordLength = 0;
  int _passwordPaddingLength = 0;
  int _reservedDataLength = 0;
  int _reservedDataPaddingLength = 0;

  set isSsidEncoded(bool value) {
    _isSsidEncoded = value;
    _ssidPaddingFactor = value ? 5 : 6;
  }

  set isPasswordEncoded(bool value) {
    _isPasswordEncoded = value;
    _passwordPaddingFactor = value ? 5 : 6;
  }

  set isReservedDataEncoded(bool value) {
    _isReservedDataEncoded = value;
    _reservedPaddingFactor = value ? 5 : 6;
  }

  EspProvisioningPackage(this.request, this.portIndex, { required Logger logger }) {
    _logger = logger;
    _parse();
  }

  void _parse() {
    final dataTmp = <int>[];

    dataTmp.addAll(_head());

    if (request.password != null) {
      _passwordLength = request.password!.length;
      dataTmp.addAll(request.password!);

      if(_isPasswordEncoded || _isReservedDataEncoded) {
        final padding = _padding(_passwordPaddingFactor, request.password);
        _passwordPaddingLength = padding.length;
        dataTmp.addAll(padding);
      }
    }

    if (request.reservedData != null) {
      _reservedDataLength = request.reservedData!.length;
      dataTmp.addAll(request.reservedData!);

      if(_isPasswordEncoded || _isReservedDataEncoded) {
        final padding = _padding(_reservedPaddingFactor, request.reservedData);
        _reservedDataPaddingLength = padding.length;
        dataTmp.addAll(padding);
      }
    }

    dataTmp.addAll(request.ssid);
    dataTmp.addAll(_padding(_ssidPaddingFactor, request.ssid));

    _buffer = Int8List.fromList(dataTmp);
    dataTmp.clear();

    _logger.verbose(
      "paddings "
      "password=$_passwordPaddingLength, "
      "reserved_data=$_reservedDataPaddingLength"
    );

    _logger.debug("package buffer $_buffer");

    int reservedDataBeginPos =
        _headLength + _passwordLength + _passwordPaddingLength;
    int ssidBeginPos =
        reservedDataBeginPos + _reservedDataLength + _reservedDataPaddingLength;
    int offset = 0;
    int count = 0;

    while (offset < _buffer.length) {
      int expectLength;
      bool tailIsCrc;

      if (count == 0) {
        tailIsCrc = false;
        expectLength = 6;
      } else {
        if (offset < reservedDataBeginPos) {
          tailIsCrc = !isPasswordEncoded;
          expectLength = _passwordPaddingFactor;
        } else if (offset < ssidBeginPos) {
          tailIsCrc = !isReservedDataEncoded;
          expectLength = _reservedPaddingFactor;
        } else {
          tailIsCrc = !isSsidEncoded;
          expectLength = _ssidPaddingFactor;
        }
      }

      final buf = Int8List(6);
      final read =
          Int8List.fromList(_buffer.skip(offset).take(expectLength).toList());
      buf.setAll(0, read);
      if (read.length <= 0) {
        break;
      }
      offset += read.length;

      final crc = EspProvisioningCrc.calculate(read);
      if (expectLength < buf.length) {
        buf.buffer.asByteData().setInt8(buf.length - 1, crc);
      }

      _createBlocksFor6Bytes(buf, count - 1, crc, tailIsCrc);
      count++;
    }

    _updateBlocksForSequencesLength(count);
  }

  void _createBlocksFor6Bytes(
      Int8List buf, int sequence, int crc, bool tailIsCrc) {
    _logger.verbose("buf=$buf, seq=$sequence, crc=$crc, tailIsCrc=$tailIsCrc");

    if (sequence == -1) {
      // first sequence
      final syncBlock = _syncBlock();
      final seqSizeBlock = Int8List(0);

      _blocks.addAll([
        syncBlock,
        seqSizeBlock,
        syncBlock,
        seqSizeBlock,
      ]);
    } else {
      final seqBlock = _seqBlock(sequence);

      _blocks.addAll([
        seqBlock,
        seqBlock,
        seqBlock,
      ]);
    }

    for (int bit = 0; bit < (tailIsCrc ? 7 : 8); bit++) {
      int data = (buf[5] >> bit & 1) |
          ((buf[4] >> bit & 1) << 1) |
          ((buf[3] >> bit & 1) << 2) |
          ((buf[2] >> bit & 1) << 3) |
          ((buf[1] >> bit & 1) << 4) |
          ((buf[0] >> bit & 1) << 5);

      _blocks.add(_dataBlock(data, bit));
    }

    if (tailIsCrc) {
      _blocks.add(_dataBlock(crc, 7));
    }
  }

  void _updateBlocksForSequencesLength(int size) {
    _blocks[1] = _blocks[3] = _seqSizeBlock(size);
  }

  Int8List _syncBlock() => Int8List(1048);
  Int8List _seqSizeBlock(int size) => Int8List(1072 + size - 1);
  Int8List _seqBlock(int seq) => Int8List(128 + seq);
  Int8List _dataBlock(int data, int idx) =>
      Int8List((idx << 7) | (1 << 6) | data);

  Int8List _head() {
    final headTmp = <int>[];

    isSsidEncoded = _isEncoded(request.ssid);
    headTmp.add(request.ssid.length | (_isSsidEncoded ? 0x80 : 0));

    if (request.password == null) {
      headTmp.add(0);
    } else {
      isPasswordEncoded = _isEncoded(request.password!);
      headTmp.add(request.password!.length | (_isPasswordEncoded ? 0x80 : 0));
    }

    if (request.reservedData == null) {
      headTmp.add(0);
    } else {
      isReservedDataEncoded = _isEncoded(request.reservedData!);
      headTmp.add(
          request.reservedData!.length | (_isReservedDataEncoded ? 0x80 : 0));
    }

    headTmp.add(EspProvisioningCrc.calculate(request.bssid));

    final flag = (1) // bit0 : 1-ipv4, 0-ipv6
        |
        ((0) << 1) // bit1 bit2 : 00-no crypt, 01-crypt
        |
        ((portIndex & 0x03) << 3) // bit3 bit4 : app port
        |
        ((EspProvisioner.version & 0x03) << 6); // bit6 bit7 : version

    headTmp.add(flag);

    headTmp.add(EspProvisioningCrc.calculate(Int8List.fromList(headTmp)));
    _headLength = headTmp.length;

    return Int8List.fromList(headTmp);
  }

  Int8List _padding(int factor, Int8List? data) {
    int length = factor - (data == null ? 0 : data.length) % factor;
    return Int8List(length < factor ? length : 0);
  }

  bool _isEncoded(Int8List data) {
    for (var b in data) {
      if (b < 0) {
        return true;
      }
    }

    return false;
  }
}
