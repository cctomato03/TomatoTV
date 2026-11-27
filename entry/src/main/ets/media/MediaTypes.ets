import { image } from '@kit.ImageKit';

export interface TrackOption {
  index: number;
  label: string;
  isSubtitle: boolean;
}

export interface VideoState {
  loading: boolean;
  title: string;
  playing: boolean;
  buffering: boolean;
  durationMs: number;
  positionMs: number;
  speed: number;
  audioTracks: TrackOption[];
  subtitleTracks: TrackOption[];
  selectedAudioId: number;
  selectedSubtitleId: number;
  subtitleText: string;
  error: string | null;
}

export interface PlaylistItem {
  path: string;
  name: string;
  size: number;
}

export interface AudioState {
  loading: boolean;
  title: string;
  artist: string;
  album: string;
  playing: boolean;
  durationMs: number;
  positionMs: number;
  speed: number;
  albumArt: image.PixelMap | null;
  playlist: PlaylistItem[];
  playlistIndex: number;
  lyrics: string | null;
  lyricsLoading: boolean;
  lyricsError: string | null;
  playbackError: string | null;
}

export class MediaDefaults {
  static videoState(title: string): VideoState {
    return {
      loading: true,
      title: title,
      playing: false,
      buffering: false,
      durationMs: 0,
      positionMs: 0,
      speed: 1,
      audioTracks: [],
      subtitleTracks: [],
      selectedAudioId: -1,
      selectedSubtitleId: -1,
      subtitleText: '',
      error: null
    };
  }

  static audioState(): AudioState {
    return {
      loading: true,
      title: '',
      artist: '',
      album: '',
      playing: false,
      durationMs: 0,
      positionMs: 0,
      speed: 1,
      albumArt: null,
      playlist: [],
      playlistIndex: 0,
      lyrics: null,
      lyricsLoading: false,
      lyricsError: null,
      playbackError: null
    };
  }
}

export class PlaybackSpeeds {
  static readonly LIST: number[] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3];

  static label(speed: number): string {
    return `${speed}x`;
  }
}
