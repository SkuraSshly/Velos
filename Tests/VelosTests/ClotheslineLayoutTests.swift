import CoreGraphics
import Testing
@testable import Velos

/// 晾衣绳的排列：居中、间隔一致、挂不下时挤近一点但不出屏幕；绳子中间往下坠
@Suite struct ClotheslineLayoutTests {
    @Test func 照片居中_间隔一致() {
        let xs = (0..<3).map { ClotheslineLayout.x(index: $0, count: 3, width: 1440, visible: 8, scroll: 0) }
        #expect(abs(xs[1] - 720) < 0.01)
        #expect(abs((xs[1] - xs[0]) - ClotheslineLayout.spacing) < 0.01)
    }

    @Test func 挂不下时挤近_不超出屏幕() {
        let count = 12
        let xs = (0..<count).map { ClotheslineLayout.x(index: $0, count: count, width: 1000, visible: 4, scroll: 0) }
        #expect(xs.first! >= 100 - 0.01 && xs.last! <= 900 + 0.01)
    }

    @Test func 屏幕越宽挂得越多() {
        #expect(ClotheslineLayout.capacity(width: 1440) > ClotheslineLayout.capacity(width: 800))
        // 再窄也至少 3 张，再宽最多 12 张
        #expect(ClotheslineLayout.capacity(width: 100) == 3)
        #expect(ClotheslineLayout.capacity(width: 10000) == 12)
    }

    @Test func 绳子中间最低_两头最高() {
        let w: CGFloat = 1440
        #expect(ClotheslineLayout.ropeY(x: w / 2, width: w) > ClotheslineLayout.ropeY(x: 10, width: w))
        #expect(ClotheslineLayout.ropeY(x: 0, width: w) == ClotheslineLayout.ropeTop)
    }
}
