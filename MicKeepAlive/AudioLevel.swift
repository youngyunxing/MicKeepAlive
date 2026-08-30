import Foundation
import AVFoundation
import CoreMedia

/// 从 CMSampleBuffer 计算 RMS 归一化电平（0~1）。
/// App 与 mkctl probe 共用，保证两侧电平可比（探针验证依赖同一套算法）。
/// 注意：不同设备/会话输出的采样格式不同（Float32 或 Int16），必须按格式描述读取，
/// 否则把 Int16 当 Float32 读会得到垃圾值（电平恒为 1.0）。
enum AudioLevel {
    static func calculate(from sampleBuffer: CMSampleBuffer) -> Float {
        // 确定采样格式：Float32 还是 Int16
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return 0
        }
        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = asbd.pointee.mBitsPerChannel

        // 先询问需要多大的 AudioBufferList
        var bufferListSize = 0
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer) == noErr,
            bufferListSize > 0 else {
            return 0
        }

        // 分配并填充 AudioBufferList
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: bufferListSize)
        defer { bufferList.deallocate() }
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer) == noErr else {
            return 0
        }

        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        var sum: Float = 0
        var totalSamples = 0
        for buffer in abl {
            guard let data = buffer.mData else { continue }
            if isFloat {
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard sampleCount > 0 else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<sampleCount {
                    let sample = samples[i]
                    sum += sample * sample
                }
                totalSamples += sampleCount
            } else if bitsPerChannel == 16 {
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                guard sampleCount > 0 else { continue }
                let samples = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<sampleCount {
                    let sample = Float(samples[i]) / 32768.0
                    sum += sample * sample
                }
                totalSamples += sampleCount
            }
            // 其他位深暂不支持，跳过该 buffer
        }
        guard totalSamples > 0 else { return 0 }

        let rms = sqrt(sum / Float(totalSamples))
        let db = 20 * log10(max(rms, 0.00001))
        let normalized = (db + 60) / 60
        return max(0, min(1, normalized))
    }
}
