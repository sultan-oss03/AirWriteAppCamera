import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:permission_handler/permission_handler.dart';

// --- Global Variable ---
late List<CameraDescription> _cameras;

// --- Main Entry Point ---
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } on CameraException catch (e) {
    debugPrint('Camera Error: ${e.description}');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Air Write AI',
      theme: ThemeData.dark(),
      home: const AirWritingScreen(),
    );
  }
}

// --- Main Screen Logic ---
class AirWritingScreen extends StatefulWidget {
  const AirWritingScreen({super.key});

  @override
  State<AirWritingScreen> createState() => _AirWritingScreenState();
}

class _AirWritingScreenState extends State<AirWritingScreen> {
  CameraController? _controller;
  final PoseDetector _poseDetector = PoseDetector(options: PoseDetectorOptions(mode: PoseDetectionMode.stream));
  bool _isBusy = false;
  List<Offset?> _points = [];
  double _scaleX = 1.0;
  double _scaleY = 1.0;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    await Permission.camera.request();
    
    if (_cameras.isEmpty) return;

    final frontCamera = _cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => _cameras.first,
    );

    _controller = CameraController(
      frontCamera,
      ResolutionPreset.low, // Performance optimized for older devices
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );

    try {
      await _controller!.initialize();
      if (!mounted) return;
      _controller!.startImageStream(_processCameraImage);
      setState(() {});
    } catch (e) {
      debugPrint("Camera Init Error: $e");
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isBusy) return;
    _isBusy = true;

    try {
      final inputImage = _inputImageFromCameraImage(image, _controller!.description);
      final poses = await _poseDetector.processImage(inputImage);

      if (poses.isNotEmpty) {
        final pose = poses.first;
        final PoseLandmark? indexFinger = pose.landmarks[PoseLandmarkType.rightIndex];
        
        if (indexFinger != null && indexFinger.likelihood > 0.5) {
          _updateDrawingPoint(indexFinger, image.height, image.width);
        } else {
           _addBreak();
        }
      } else {
        _addBreak();
      }
    } catch (e) {
      debugPrint("AI Processing Error: $e");
    } finally {
      _isBusy = false;
    }
  }

  void _addBreak() {
    if (_points.isNotEmpty && _points.last != null) {
      _points.add(null);
    }
  }

  void _updateDrawingPoint(PoseLandmark landmark, int imgH, int imgW) {
    if (!mounted) return;
    
    // Swap width/height because camera sensor is often rotated 90 degrees
    final double camW = imgH.toDouble(); 
    final double camH = imgW.toDouble();
    final Size screen = MediaQuery.of(context).size;

    _scaleX = screen.width / camW;
    _scaleY = screen.height / camH;

    // Mirror logic for front camera
    double x = (camW - landmark.x) * _scaleX; 
    double y = landmark.y * _scaleY;

    // Optional: Add simple smoothing here if needed
    setState(() {
      _points.add(Offset(x, y));
    });
  }
  
  // --- Helper: Convert CameraImage to InputImage ---
  InputImage _inputImageFromCameraImage(CameraImage image, CameraDescription camera) {
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isAndroid) {
      var rotationCompensation = _orientations[ui.window.currentDeviceOrientation] ?? 0;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation = (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    rotation ??= InputImageRotation.rotation0deg;

    final format = InputImageFormatValue.fromRawValue(image.format.raw) ?? InputImageFormat.nv21;
    
    final plane = image.planes.first;
    
    return InputImage.fromBytes(
      bytes: _concatenatePlanes(image.planes),
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Uint8List _concatenatePlanes(List<Plane> planes) {
    final WriteBuffer allBytes = WriteBuffer();
    for (Plane plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  static final _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  void dispose() {
    _controller?.dispose();
    _poseDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SizedBox.expand(child: CameraPreview(_controller!)),
          SizedBox.expand(
            child: CustomPaint(
              painter: AirPainter(points: _points, color: Colors.cyanAccent),
            ),
          ),
          Positioned(
            bottom: 30, right: 20,
            child: FloatingActionButton(
              backgroundColor: Colors.redAccent,
              onPressed: () => setState(() => _points.clear()),
              child: const Icon(Icons.delete_forever),
            ),
          ),
          Positioned(
            top: 50, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                child: const Text("Point Index Finger to Write", style: TextStyle(color: Colors.white)),
              ),
            ),
          )
        ],
      ),
    );
  }
}

// --- Custom Painter Class ---
class AirPainter extends CustomPainter {
  final List<Offset?> points;
  final Color color;
  AirPainter({required this.points, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    Paint paint = Paint()..color = color..strokeCap = StrokeCap.round..strokeWidth = 6.0..isAntiAlias = true;
    for (int i = 0; i < points.length - 1; i++) {
      if (points[i] != null && points[i + 1] != null) {
        canvas.drawLine(points[i]!, points[i + 1]!, paint);
      }
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
