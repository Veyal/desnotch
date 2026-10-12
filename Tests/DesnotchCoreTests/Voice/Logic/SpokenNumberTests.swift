import XCTest
@testable import DesnotchCore

final class SpokenNumberTests: XCTestCase {
    func testS1_digitFive() { assertParse(["5"], 0, (5, 1)) }

    func testS2_digitBeforeWord() { assertParse(["30", "percent"], 0, (30, 1)) }

    func testS3_digitHundred() { assertParse(["100"], 0, (100, 1)) }

    func testS4_digitTwoFifty() { assertParse(["250"], 0, (250, 1)) }

    func testS5_fourDigitsIsNotANumber() { assertParse(["1000"], 0, nil) }

    func testS6_zero() { assertParse(["zero"], 0, (0, 1)) }

    func testS7_nol() { assertParse(["nol"], 0, (0, 1)) }

    func testS8_ten() { assertParse(["ten"], 0, (10, 1)) }

    func testS9_thirteen() { assertParse(["thirteen"], 0, (13, 1)) }

    func testS10_twenty() { assertParse(["twenty"], 0, (20, 1)) }

    func testS11_twentyFive() { assertParse(["twenty", "five", "percent"], 0, (25, 2)) }

    func testS12_ninetyNine() { assertParse(["ninety", "nine"], 0, (99, 2)) }

    func testS13_hundred() { assertParse(["hundred"], 0, (100, 1)) }

    func testS14_oneHundred() { assertParse(["one", "hundred"], 0, (100, 2)) }

    func testS15_aHundred() { assertParse(["a", "hundred"], 0, (100, 2)) }

    func testS16_twentyTenIsTwenty() { assertParse(["twenty", "ten"], 0, (20, 1)) }

    func testS17_fiveFiveIsFive() { assertParse(["five", "five"], 0, (5, 1)) }

    func testS18_fifteen() { assertParse(["fifteen", "minutes"], 0, (15, 1)) }

    func testS19_sepuluh() { assertParse(["sepuluh"], 0, (10, 1)) }

    func testS20_sebelas() { assertParse(["sebelas"], 0, (11, 1)) }

    func testS21_duaBelas() { assertParse(["dua", "belas"], 0, (12, 2)) }

    func testS22_limaBelas() { assertParse(["lima", "belas"], 0, (15, 2)) }

    func testS23_satuBelasIsNotAPair() { assertParse(["satu", "belas"], 0, (1, 1)) }

    func testS24_duaPuluh() { assertParse(["dua", "puluh"], 0, (20, 2)) }

    func testS25_duaPuluhLima() { assertParse(["dua", "puluh", "lima"], 0, (25, 3)) }

    func testS26_tujuhPuluhPersen() { assertParse(["tujuh", "puluh", "persen"], 0, (70, 2)) }

    func testS27_seratus() { assertParse(["seratus"], 0, (100, 1)) }

    func testS28_startOffset() { assertParse(["volume", "30"], 1, (30, 1)) }

    func testS29_wordIsNotANumber() { assertParse(["volume", "30"], 0, nil) }

    func testS30_bananaIsNotANumber() { assertParse(["banana"], 0, nil) }

    func testS31_emptyTokens() { assertParse([], 0, nil) }

    func testS32_startOutOfRange() { assertParse(["30"], 5, nil) }

    func testS33_lettersWithDigitIsNotADigitToken() { assertParse(["x5"], 0, nil) }

    func testS34_limaPuluh() { assertParse(["lima", "puluh"], 0, (50, 2)) }
}

private func assertParse(_ tokens: [String], _ start: Int, _ expected: (Int, Int)?,
                         file: StaticString = #filePath, line: UInt = #line) {
    let result = SpokenNumber.parse(tokens, at: start)
    XCTAssertEqual(result == nil, expected == nil, "nil-ness of \(tokens) at \(start)",
                   file: file, line: line)
    if let result, let expected {
        XCTAssertEqual(result.value, expected.0, file: file, line: line)
        XCTAssertEqual(result.length, expected.1, file: file, line: line)
    }
}
