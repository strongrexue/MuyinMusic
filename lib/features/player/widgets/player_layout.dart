// Horizontal insets shared by the progress track and lyric text.
const double playerCompactOuterInset = 8;
const double playerContentInset = 16;
const double playerProgressTrackInset = 4;
const double playerWideOuterInset = 32;
const double playerWideColumnGap = 24;
const double playerWideTransportMaxWidth = 560;

/// Centre-to-centre pitch of the phone-landscape merged control row.
/// All ten buttons (action segments around the transport cluster) form
/// one centred group on this pitch, so the row reads as a single
/// series instead of three split clusters.
const double playerLandscapeControlPitch = 62;

/// Gap between two neighbouring 48dp buttons on the landscape pitch.
const double playerLandscapeControlGap = playerLandscapeControlPitch - 48;

/// Gap between the 72dp play button and a neighbouring 48dp button on
/// the landscape pitch.
const double playerLandscapeControlPlayGap = playerLandscapeControlPitch - 60;
