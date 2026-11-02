export function functionalQaPassed(report) {
  return !report.aborted && !report.fatal && Array.isArray(report.steps) &&
    report.steps.length > 0 && report.steps.every((step) => step.ok === true)
}
