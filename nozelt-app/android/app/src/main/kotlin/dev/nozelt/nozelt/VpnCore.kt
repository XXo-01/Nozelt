package dev.nozelt.nozelt

internal enum class VpnCore(
    val wireName: String,
    val displayName: String,
) {
    MIHOMO("mihomo", "Mihomo"),
    XRAY("xray", "Xray"),
    SING_BOX("sing_box", "sing-box");

    companion object {
        fun fromWireName(value: String?): VpnCore =
            entries.firstOrNull { it.wireName == value } ?: MIHOMO
    }
}
