package com.csus.ahha.ahha_app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.objectdetector.ObjectDetector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.util.concurrent.Executors

// On-device furniture detection (Google MediaPipe Object Detector,
// EfficientDet-Lite0 int8, COCO labels). Dart side: lib/furniture_detection.dart.
//
// Contract with Dart: channel "ahha/furniture", method "detect" with
// {"jpeg": ByteArray}; returns a list of {label, score, x1, y1, x2, y2} with
// the box normalised 0..1 against the UPRIGHT image. Every failure is reported
// as a channel error; Dart treats that as "no detections this frame".
class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var detector: ObjectDetector? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ahha/furniture")
            .setMethodCallHandler { call, result ->
                if (call.method != "detect") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val jpeg = call.argument<ByteArray>("jpeg")
                if (jpeg == null) {
                    result.error("bad_args", "jpeg is missing", null)
                    return@setMethodCallHandler
                }
                // Off the UI thread: decoding and inference are not cheap.
                worker.execute {
                    try {
                        val boxes = detect(jpeg)
                        runOnUiThread { result.success(boxes) }
                    } catch (t: Throwable) {
                        runOnUiThread { result.error("detect_failed", t.message ?: t.javaClass.simpleName, null) }
                    }
                }
            }
    }

    private fun detector(): ObjectDetector {
        detector?.let { return it }
        val options = ObjectDetector.ObjectDetectorOptions.builder()
            .setBaseOptions(BaseOptions.builder().setModelAssetPath("efficientdet_lite0.tflite").build())
            .setRunningMode(RunningMode.IMAGE)
            .setScoreThreshold(0.30f) // lowest threshold any kept class uses; Dart filters the rest
            .setMaxResults(15)
            .build()
        return ObjectDetector.createFromOptions(applicationContext, options).also { detector = it }
    }

    private fun detect(jpeg: ByteArray): List<Map<String, Any>> {
        val decoded = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
            ?: throw IllegalArgumentException("not a decodable JPEG")
        val upright = rotateUpright(decoded, jpeg)
        try {
            val w = upright.width.toFloat()
            val h = upright.height.toFloat()
            val result = detector().detect(BitmapImageBuilder(upright).build())
            val out = ArrayList<Map<String, Any>>()
            for (d in result.detections()) {
                val best = d.categories().maxByOrNull { it.score() } ?: continue
                val b = d.boundingBox()
                out.add(
                    mapOf(
                        "label" to best.categoryName(),
                        "score" to best.score().toDouble(),
                        "x1" to (b.left / w).toDouble().coerceIn(0.0, 1.0),
                        "y1" to (b.top / h).toDouble().coerceIn(0.0, 1.0),
                        "x2" to (b.right / w).toDouble().coerceIn(0.0, 1.0),
                        "y2" to (b.bottom / h).toDouble().coerceIn(0.0, 1.0),
                    )
                )
            }
            return out
        } finally {
            if (upright !== decoded) upright.recycle()
            decoded.recycle()
        }
    }

    // CameraX stores the phone's rotation as an EXIF tag; BitmapFactory ignores
    // it, and a sideways picture would give meaningless boxes.
    private fun rotateUpright(bitmap: Bitmap, jpeg: ByteArray): Bitmap {
        val orientation = try {
            ExifInterface(ByteArrayInputStream(jpeg))
                .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (_: Throwable) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val m = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> m.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> m.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.postScale(1f, -1f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
    }

    override fun onDestroy() {
        detector?.close()
        detector = null
        worker.shutdown()
        super.onDestroy()
    }
}
