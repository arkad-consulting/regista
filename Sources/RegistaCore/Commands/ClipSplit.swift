import Foundation

extension Clip {
    /// Splits the clip `d` after its start (0 < d < duration): the left part keeps the id, the right part gets
    /// `rightID`. Clip-relative keyframes and effect windows follow their media: the right part's are shifted, and a
    /// keyframe is added at the cut on both sides when an animation runs through it.
    func split(at d: MediaTime, rightID: String) -> (Clip, Clip) {
        var left = self, right = self
        right.id = rightID
        right.start = start + d
        if let sp = speed {
            // Retimed: each half keeps the speed, with the source it actually plays and its own duration.
            var ls = sp, rs = sp
            ls.duration = d
            rs.duration = sp.duration - d
            if sp.freeze != true {
                let span = sourceDuration.seconds
                let c = MediaTime(seconds: sp.consumed(atTimeline: d.seconds, span: span))
                if sp.reverse == true {
                    left.sourceIn = sourceOut - c
                    right.sourceOut = sourceOut - c
                    rs.proxyStart = (sp.proxyStart ?? 0) + c.seconds
                } else {
                    left.sourceOut = sourceIn + c
                    right.sourceIn = sourceIn + c
                    rs.ramp = sp.ramp?.map { ScalarKey(time: $0.time - c, value: $0.value, easing: $0.easing) }
                }
            }
            left.speed = ls
            right.speed = rs
        } else {
            left.sourceOut = sourceIn + d
            right.sourceIn = left.sourceOut
        }
        // A picture fade belongs to the outer edge it was set on, never to the cut.
        left.pictureFadeOut = nil
        right.pictureFadeIn = nil
        if let ks = keyframes, !ks.isEmpty {
            let atCut = transform(at: d)
            let segment = ks.last { $0.time <= d }?.easing
            var l = ks.filter { $0.time < d }
            if ks.contains(where: { $0.time >= d }) { l.append(Keyframe(time: d, transform: atCut, easing: nil)) }
            var r = ks.filter { $0.time > d }.map { Keyframe(time: $0.time - d, transform: $0.transform, easing: $0.easing) }
            if ks.contains(where: { $0.time <= d }) { r.insert(Keyframe(time: .zero, transform: atCut, easing: segment), at: 0) }
            left.keyframes = l.isEmpty ? nil : l
            right.keyframes = r.isEmpty ? nil : r
        }
        if let es = effects, !es.isEmpty {
            left.effects = es.filter { ($0.start ?? .zero) < d || $0.keyframes?.isEmpty == false }
            right.effects = es.compactMap { e -> Effect? in
                var e = e
                if let k = e.keyframes, !k.isEmpty {
                    e.keyframes = k.map { ScalarKey(time: $0.time > d ? $0.time - d : .zero, value: $0.value, easing: $0.easing) }
                    return e
                }
                let end = e.end ?? duration
                guard end > d else { return nil }
                e.start = (e.start ?? .zero) > d ? (e.start ?? .zero) - d : nil
                e.end = e.end.map { $0 - d }
                return e
            }
            if left.effects?.isEmpty == true { left.effects = nil }
            if right.effects?.isEmpty == true { right.effects = nil }
        }
        return (left, right)
    }
}
