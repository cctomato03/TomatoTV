/** 一条字幕：起止时间（毫秒）与文本 */
export interface SubtitleCue {
  startMs: number;
  endMs: number;
  text: string;
}

/** 轻量外挂字幕解析：SRT / VTT / ASS(SSA) */
export class SubtitleParser {
  static parse(content: string, extension: string): SubtitleCue[] {
    const ext: string = extension.toLowerCase();
    const normalized: string = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    if (ext === 'ass' || ext === 'ssa') {
      return SubtitleParser.parseAss(normalized);
    }
    return SubtitleParser.parseSrtOrVtt(normalized);
  }

  private static parseSrtOrVtt(content: string): SubtitleCue[] {
    const cues: SubtitleCue[] = [];
    const blocks: string[] = content.split('\n\n');
    for (const block of blocks) {
      const lines: string[] = block.split('\n');
      let timeLineIndex: number = -1;
      for (let i = 0; i < lines.length; i++) {
        if (lines[i].indexOf('-->') >= 0) {
          timeLineIndex = i;
          break;
        }
      }
      if (timeLineIndex < 0) {
        continue;
      }
      const arrow: number = lines[timeLineIndex].indexOf('-->');
      const startText: string = lines[timeLineIndex].substring(0, arrow).trim();
      let endText: string = lines[timeLineIndex].substring(arrow + 3).trim();
      const space: number = endText.indexOf(' ');
      if (space > 0) {
        endText = endText.substring(0, space);
      }
      const startMs: number = SubtitleParser.parseTime(startText);
      const endMs: number = SubtitleParser.parseTime(endText);
      if (startMs < 0 || endMs <= startMs) {
        continue;
      }
      const textLines: string[] = [];
      for (let i = timeLineIndex + 1; i < lines.length; i++) {
        const line: string = lines[i].trim();
        if (line.length > 0) {
          textLines.push(SubtitleParser.stripMarkup(line));
        }
      }
      const text: string = textLines.join('\n');
      if (text.length > 0) {
        cues.push({ startMs: startMs, endMs: endMs, text: text });
      }
    }
    cues.sort((a: SubtitleCue, b: SubtitleCue): number => a.startMs - b.startMs);
    return cues;
  }

  private static parseAss(content: string): SubtitleCue[] {
    const cues: SubtitleCue[] = [];
    const lines: string[] = content.split('\n');
    for (const line of lines) {
      const trimmed: string = line.trim();
      if (trimmed.indexOf('Dialogue:') !== 0) {
        continue;
      }
      const body: string = trimmed.substring(9).trim();
      const parts: string[] = body.split(',');
      if (parts.length < 10) {
        continue;
      }
      const startMs: number = SubtitleParser.parseTime(parts[1].trim());
      const endMs: number = SubtitleParser.parseTime(parts[2].trim());
      if (startMs < 0 || endMs <= startMs) {
        continue;
      }
      let text: string = '';
      for (let i = 9; i < parts.length; i++) {
        text += (i > 9 ? ',' : '') + parts[i];
      }
      text = SubtitleParser.stripMarkup(text).split('\\N').join('\n').split('\\n').join('\n');
      if (text.length > 0) {
        cues.push({ startMs: startMs, endMs: endMs, text: text });
      }
    }
    cues.sort((a: SubtitleCue, b: SubtitleCue): number => a.startMs - b.startMs);
    return cues;
  }

  private static parseTime(raw: string): number {
    const text: string = raw.replace(',', '.').trim();
    const parts: string[] = text.split(':');
    if (parts.length < 2 || parts.length > 3) {
      return -1;
    }
    let hours: number = 0;
    let minutes: number = 0;
    let secondsPart: string = '';
    if (parts.length === 3) {
      hours = Number(parts[0]);
      minutes = Number(parts[1]);
      secondsPart = parts[2];
    } else {
      minutes = Number(parts[0]);
      secondsPart = parts[1];
    }
    if (!Number.isFinite(hours) || !Number.isFinite(minutes)) {
      return -1;
    }
    const secParts: string[] = secondsPart.split('.');
    const seconds: number = Number(secParts[0]);
    if (!Number.isFinite(seconds)) {
      return -1;
    }
    let millis: number = 0;
    if (secParts.length > 1) {
      let frac: string = secParts[1];
      if (frac.length > 3) {
        frac = frac.substring(0, 3);
      }
      while (frac.length < 3) {
        frac += '0';
      }
      millis = Number(frac);
      if (!Number.isFinite(millis)) {
        millis = 0;
      }
    }
    return Math.round(hours * 3600000 + minutes * 60000 + seconds * 1000 + millis);
  }

  private static stripMarkup(raw: string): string {
    let text: string = raw;
    while (true) {
      const start: number = text.indexOf('{');
      if (start < 0) {
        break;
      }
      const end: number = text.indexOf('}', start + 1);
      if (end < 0) {
        break;
      }
      text = text.substring(0, start) + text.substring(end + 1);
    }
    while (true) {
      const start: number = text.indexOf('<');
      if (start < 0) {
        break;
      }
      const end: number = text.indexOf('>', start + 1);
      if (end < 0) {
        break;
      }
      text = text.substring(0, start) + text.substring(end + 1);
    }
    return text.trim();
  }
}