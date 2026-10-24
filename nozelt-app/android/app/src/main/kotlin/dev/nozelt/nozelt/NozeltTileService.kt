package dev.nozelt.nozelt

import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Quick Settings toggle that connects the last selected Nozelt server. */
class NozeltTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        refreshTile()
    }

    override fun onClick() {
        super.onClick()
        unlockAndRun {
            if (NozeltVpnService.isRequested(this)) {
                startService(
                    Intent(this, NozeltVpnService::class.java).apply {
                        action = NozeltVpnService.ACTION_STOP
                    },
                )
                refreshTile()
            } else {
                openNozeltAndConnect()
            }
        }
    }

    private fun refreshTile() {
        val tile = qsTile ?: return
        val active = NozeltVpnService.isRequested(this)
        tile.icon = Icon.createWithResource(this, R.drawable.ic_nozelt_tile)
        tile.label = getString(R.string.quick_settings_tile_label)
        tile.state = if (active) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = getString(
                if (active) {
                    R.string.quick_settings_tile_active
                } else {
                    R.string.quick_settings_tile_inactive
                },
            )
        }
        tile.updateTile()
    }

    private fun openNozeltAndConnect() {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_CONNECT_FROM_TILE, true)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pendingIntent = PendingIntent.getActivity(
                this,
                20,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            startActivityAndCollapse(pendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
