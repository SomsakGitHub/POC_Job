import TradeCore

/// One symbol the simulated market trades.
///
/// The ticker is a real SET-style short name; the reference price is invented, like every number in the simulation.
public struct SymbolInfo: Sendable, Equatable {
    /// The id the wire and the order API use. In the default catalog it is 1 through 12 in array order.
    public let id: UInt32
    public let ticker: String
    public let nameTh: String
    public let nameEn: String
    /// The reference ("previous close") price, in satang: the centre of the price band and of the simulated walk.
    public let reference: Price

    public init(id: UInt32, ticker: String, nameTh: String, nameEn: String, reference: Price) {
        self.id = id
        self.ticker = ticker
        self.nameTh = nameTh
        self.nameEn = nameEn
        self.reference = reference
    }
}

/// The twelve symbols of the default market.
public enum SymbolCatalog: Sendable {
    /// Twelve well-known SET large caps, ids 1 through 12 in array order, PTT first.
    ///
    /// Every reference price is invented (these are not quotes), written in satang, and is itself on a tick. They are
    /// spread over five tick sizes (10, 25, 50, 100 and 200 satang), and several price bands straddle a change of tick
    /// size (DELTA at 100.00 baht, KTB and BDMS at 25.00), so the simulated walk has to cross one.
    ///
    /// This app names no bank brand of its own: no ticker or name here refers to one particular bank or any of its
    /// brands, and the catalog tests scan every field for it.
    public static let defaultSymbols: [SymbolInfo] = [
        symbol(1, "PTT", "ปตท.", "PTT Public Company", satang: 3425),  // 34.25 baht
        symbol(2, "AOT", "ท่าอากาศยานไทย", "Airports of Thailand", satang: 5800),  // 58.00
        symbol(3, "BBL", "ธนาคารกรุงเทพ", "Bangkok Bank", satang: 15_250),  // 152.50
        symbol(4, "CPALL", "ซีพี ออลล์", "CP ALL", satang: 6175),  // 61.75
        symbol(5, "ADVANC", "แอดวานซ์ อินโฟร์ เซอร์วิส", "Advanced Info Service", satang: 28_100),  // 281.00
        symbol(6, "SCB", "ธนาคารไทยพาณิชย์", "Siam Commercial Bank", satang: 12_450),  // 124.50
        symbol(7, "KTB", "ธนาคารกรุงไทย", "Krung Thai Bank", satang: 2040),  // 20.40
        symbol(8, "GULF", "กัลฟ์ เอ็นเนอร์ยี ดีเวลลอปเมนท์", "Gulf Energy Development", satang: 5950),  // 59.50
        symbol(9, "DELTA", "เดลต้า อีเลคโทรนิคส์ (ประเทศไทย)", "Delta Electronics (Thailand)", satang: 9850),  // 98.50
        symbol(10, "SCC", "ปูนซิเมนต์ไทย", "Siam Cement", satang: 41_200),  // 412.00
        symbol(11, "CPN", "เซ็นทรัลพัฒนา", "Central Pattana", satang: 5225),  // 52.25
        symbol(12, "BDMS", "กรุงเทพดุสิตเวชการ", "Bangkok Dusit Medical Services", satang: 2875),  // 28.75
    ]

    private static func symbol(
        _ id: UInt32, _ ticker: String, _ nameTh: String, _ nameEn: String, satang: Int64
    ) -> SymbolInfo {
        SymbolInfo(id: id, ticker: ticker, nameTh: nameTh, nameEn: nameEn, reference: Price(satang: satang))
    }
}
