package com.example.tinigsenyas

import android.content.Intent
import android.graphics.Bitmap
import android.speech.tts.TextToSpeech
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.ImageProcessingOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import kotlin.math.max

class MainActivity : FlutterActivity() {
    private var poseLandmarker: PoseLandmarker? = null
    private var lastPoseTimestampMs = 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tinigsenyas/tts"
        ).setMethodCallHandler { call, result ->
            if (call.method == "installVoiceData") {
                try {
                    startActivity(Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA))
                    result.success(null)
                } catch (_: android.content.ActivityNotFoundException) {
                    result.error(
                        "VOICE_DATA_INSTALL_UNAVAILABLE",
                        "No Android text-to-speech voice-data installer is available.",
                        null
                    )
                }
            } else {
                result.notImplemented()
            }
        }

        val poseTaskQueue: BinaryMessenger.TaskQueue =
            flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue()
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tinigsenyas/pose_landmarker",
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
            poseTaskQueue,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> {
                    try {
                        if (poseLandmarker == null) {
                            val baseOptions = BaseOptions.builder()
                                .setModelAssetPath("pose_landmarker_lite.task")
                                .setDelegate(Delegate.CPU)
                                .build()
                            val options = PoseLandmarker.PoseLandmarkerOptions.builder()
                                .setBaseOptions(baseOptions)
                                .setRunningMode(RunningMode.VIDEO)
                                .setNumPoses(1)
                                .setMinPoseDetectionConfidence(0.5f)
                                .setMinPosePresenceConfidence(0.5f)
                                .setMinTrackingConfidence(0.5f)
                                .build()
                            poseLandmarker = PoseLandmarker.createFromOptions(
                                applicationContext,
                                options,
                            )
                        }
                        result.success(true)
                    } catch (error: Exception) {
                        poseLandmarker = null
                        result.error(
                            "POSE_LANDMARKER_INIT_FAILED",
                            error.message ?: "Could not initialize the pose model.",
                            null,
                        )
                    }
                }
                "detect" -> {
                    try {
                        val args = call.arguments as? Map<*, *>
                            ?: throw IllegalArgumentException("Missing camera frame data.")
                        val y = args.byteArray("yPlane")
                        val u = args.byteArray("uPlane")
                        val v = args.byteArray("vPlane")
                        val width = args.intValue("width")
                        val height = args.intValue("height")
                        val yRowStride = args.intValue("yRowStride")
                        val uvRowStride = args.intValue("uvRowStride")
                        val uvPixelStride = args.intValue("uvPixelStride")
                        val rotation = args.intValue("rotation")
                        val requestedTimestamp = args.longValue("timestampMs")
                        val detector = poseLandmarker
                            ?: throw IllegalStateException("Pose Landmarker is not initialized.")

                        val bitmap = yuvToBitmap(
                            ByteBuffer.wrap(y),
                            ByteBuffer.wrap(u),
                            ByteBuffer.wrap(v),
                            width,
                            height,
                            yRowStride,
                            uvRowStride,
                            uvPixelStride,
                        )
                        val mpImage = BitmapImageBuilder(bitmap).build()
                        try {
                            val timestampMs = max(lastPoseTimestampMs + 1L, requestedTimestamp)
                            lastPoseTimestampMs = timestampMs
                            val imageOptions = ImageProcessingOptions.builder()
                                .setRotationDegrees(rotation)
                                .build()
                            val pose = detector.detectForVideo(
                                mpImage,
                                imageOptions,
                                timestampMs,
                            ).landmarks().firstOrNull()
                            val points = pose?.map { landmark ->
                                mapOf(
                                    "x" to landmark.x().toDouble(),
                                    "y" to landmark.y().toDouble(),
                                    "z" to landmark.z().toDouble(),
                                )
                            } ?: emptyList()
                            result.success(points)
                        } finally {
                            mpImage.close()
                            bitmap.recycle()
                        }
                    } catch (error: Exception) {
                        result.error(
                            "POSE_LANDMARKER_FRAME_FAILED",
                            error.message ?: "Could not process the camera frame.",
                            null,
                        )
                    }
                }
                "close" -> {
                    poseLandmarker?.close()
                    poseLandmarker = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        poseLandmarker?.close()
        poseLandmarker = null
        super.onDestroy()
    }

    private fun yuvToBitmap(
        yBuffer: ByteBuffer,
        uBuffer: ByteBuffer,
        vBuffer: ByteBuffer,
        width: Int,
        height: Int,
        yRowStride: Int,
        uvRowStride: Int,
        uvPixelStride: Int,
    ): Bitmap {
        val pixels = IntArray(width * height)
        var outputIndex = 0
        for (row in 0 until height) {
            val yRowStart = row * yRowStride
            val uvRowStart = (row / 2) * uvRowStride
            for (column in 0 until width) {
                val uvOffset = uvRowStart + (column / 2) * uvPixelStride
                val luminance = (yBuffer.get(yRowStart + column).toInt() and 0xff) - 16
                val u = (uBuffer.get(uvOffset).toInt() and 0xff) - 128
                val v = (vBuffer.get(uvOffset).toInt() and 0xff) - 128
                val y1192 = if (luminance < 0) 0 else 1192 * luminance
                val red = (y1192 + 1634 * v).coerceIn(0, 262143)
                val green = (y1192 - 833 * v - 400 * u).coerceIn(0, 262143)
                val blue = (y1192 + 2066 * u).coerceIn(0, 262143)
                pixels[outputIndex++] = -0x1000000 or
                    ((red shl 6) and 0xff0000) or
                    ((green shr 2) and 0xff00) or
                    ((blue shr 10) and 0xff)
            }
        }
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
    }

    private fun Map<*, *>.byteArray(key: String): ByteArray =
        this[key] as? ByteArray ?: throw IllegalArgumentException("Missing $key data.")

    private fun Map<*, *>.intValue(key: String): Int =
        (this[key] as? Number)?.toInt()
            ?: throw IllegalArgumentException("Missing $key value.")

    private fun Map<*, *>.longValue(key: String): Long =
        (this[key] as? Number)?.toLong()
            ?: throw IllegalArgumentException("Missing $key value.")
}
