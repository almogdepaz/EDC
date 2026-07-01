export type Report = { id: string; title: string; body: string };

export function renderReport(report: Report): string {
  return `${report.title}\n${report.body}`;
}

export function formatReport(report: Report): string {
  return renderReport(report);
}

export function formatLegacyReport(report: Report): string {
  return renderReport(report);
}

export function reportToString(report: Report): string {
  return renderReport(report);
}

export function createReportAdapter(report: Report): string {
  // intentional adapter seam for the public plugin api
  return renderReport(report);
}
