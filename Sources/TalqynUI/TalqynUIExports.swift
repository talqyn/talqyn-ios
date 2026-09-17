// The conversation, the answer renderer, the history list, and the copy moved
// to TalqynConsultantCore so a storefront with its own screen does not link
// UIKit views. An app that imports TalqynUI still sees them under that one
// import: it already did before the split, and the screen's own API is
// written in their terms.
@_exported import TalqynConsultantCore
