//! One read for Settings, the toolbar and the `eink-status` verb.

use super::config::MirrorState;
use super::store::{EinkDeviceRow, EinkMirrorRow};
use crate::unified::store_api::{ImbibStore, StoreApiError};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct EinkCounts {
    pub queued: u32,
    pub awaiting_source: u32,
    pub awaiting_folder: u32,
    pub uploaded: u32,
    pub stale: u32,
    pub removed_on_device: u32,
    pub failed: u32,
    pub superseded: u32,
    pub unmarked: u32,
    /// Uploaded copies the tablet reports as changed since the last import.
    pub new_annotations: u32,
}

impl EinkCounts {
    pub fn from_rows(rows: &[EinkMirrorRow]) -> Self {
        let mut counts = Self::default();
        for row in rows {
            match row.mirror_state() {
                MirrorState::Queued => counts.queued += 1,
                MirrorState::AwaitingSource => counts.awaiting_source += 1,
                MirrorState::AwaitingFolder => counts.awaiting_folder += 1,
                MirrorState::Uploaded => counts.uploaded += 1,
                MirrorState::Stale => counts.stale += 1,
                MirrorState::RemovedOnDevice => counts.removed_on_device += 1,
                MirrorState::Failed => counts.failed += 1,
                MirrorState::Superseded => counts.superseded += 1,
                MirrorState::Unmarked => counts.unmarked += 1,
            }
            if row.mirror_state().is_on_tablet() && row.marked && row.has_new_annotations() {
                counts.new_annotations += 1;
            }
        }
        counts
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct EinkStatus {
    pub devices: Vec<EinkDeviceRow>,
    /// The device whose marks show on list rows, if any.
    pub marker_device_id: Option<String>,
    /// The device a call without a device id means.
    pub default_device_id: Option<String>,
    pub counts: EinkCounts,
    pub last_sync_at_ms: Option<i64>,
    pub last_error: Option<String>,
    pub legacy_marker_rows: u32,
}

#[cfg_attr(feature = "native", uniffi::export)]
impl ImbibStore {
    /// Devices, counts for the default device, and the marker context.
    pub fn eink_status(&self) -> Result<EinkStatus, StoreApiError> {
        let devices = self.eink_devices()?;
        let default_device = self.eink_default_device_config()?;
        let counts = match &default_device {
            Some(device) => EinkCounts::from_rows(&self.eink_mirror_rows(&device.id)?),
            None => EinkCounts::default(),
        };
        Ok(EinkStatus {
            marker_device_id: self.eink_marker_device()?,
            default_device_id: default_device.as_ref().map(|d| d.id.clone()),
            last_sync_at_ms: default_device.as_ref().and_then(|d| d.last_sync_at_ms),
            last_error: default_device.as_ref().and_then(|d| d.last_error.clone()),
            legacy_marker_rows: self.eink_legacy_marker_rows()?,
            counts,
            devices,
        })
    }
}
