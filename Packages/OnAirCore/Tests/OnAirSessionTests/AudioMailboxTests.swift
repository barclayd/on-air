import AVFAudio
import Foundation
import Testing
@testable import OnAirCore

struct AudioMailboxTests {
    private func buffers() throws -> (AVAudioPCMBuffer, AVAudioConverter, AVAudioFormat) {
        let input = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: input, to: output))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        for i in 0..<4_800 { buffer.floatChannelData![0][i] = Float(sin(Double(i) / 48_000 * 440 * 2 * .pi) * 0.2) }
        return (buffer, converter, output)
    }
    @Test func readyAudioNeverEntersTheMailbox() throws {
        let (buffer, converter, output) = try buffers(); let mailbox = AudioMailbox()
        mailbox.receive(buffer, converter: converter, output: output)
        let idle = mailbox.take()
        #expect(idle.pcm.isEmpty); #expect(idle.audioAt != nil); #expect(!idle.overflow)
        mailbox.gate(true)
        mailbox.receive(buffer, converter: converter, output: output)
        #expect(!mailbox.take().pcm.isEmpty)
        mailbox.gate(false)
        mailbox.receive(buffer, converter: converter, output: output)
        #expect(mailbox.take().pcm.isEmpty)
    }
    @Test func conversionProduces24kPCMAndVoiceLevels() throws {
        let (buffer, converter, output) = try buffers(); let mailbox = AudioMailbox()
        mailbox.gate(true)
        mailbox.receive(buffer, converter: converter, output: output)
        let batch = mailbox.take()
        #expect(batch.pcm.count >= 4_000 && batch.pcm.count <= 4_832)
        #expect(batch.pcm.count.isMultiple(of: 2))
        #expect(batch.level > 0.5 && batch.level <= 1)
        #expect(mailbox.take().pcm.isEmpty)
    }
    @Test func boundedMailboxFailsInsteadOfLosingWords() throws {
        let (buffer, converter, output) = try buffers(); let mailbox = AudioMailbox()
        mailbox.gate(true)
        for _ in 0..<30 { mailbox.receive(buffer, converter: converter, output: output) }
        let batch = mailbox.take()
        #expect(batch.overflow); #expect(batch.pcm.count <= 96_000)
        mailbox.gate(false)
        #expect(mailbox.take().pcm.isEmpty)
    }
    @Test func aNewTurnDoesNotInheritResamplerAudio() throws {
        let (buffer, converter, output) = try buffers(); let mailbox = AudioMailbox()
        mailbox.gate(true); mailbox.receive(buffer, converter: converter, output: output)
        let first = mailbox.take().pcm
        mailbox.gate(false); mailbox.gate(true)
        mailbox.receive(buffer, converter: converter, output: output)
        #expect(mailbox.take().pcm == first)
    }
}
