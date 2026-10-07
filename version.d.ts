// TypeScript declarations adapted from @rbxts/profile-store 1.0.3 by quamatic.
// https://github.com/Quamatic/rbxts-profile-store — Apache-2.0; see LICENSE.
// Modified for the CheckPickerUpper/ProfileStore fork.

import { Profile } from "./profile";

export interface VersionQuery<Template extends object, RobloxMetaData extends object = object> {
	NextAsync(): Profile<Template, RobloxMetaData> | undefined;
}
