## WIP
https://github.com/BringBackQuickPlay/castaway-plugins/tree/extensions/tf2items-bforce-in-forwards

Need to compile for Windows too, and I need to test it all.
Basically adds a extensions folder to the castaway project which will contain a pre-compiled changed version (Windows & Linux)
of nosoops TF2Items fork.
Updates the include too.

The changes I've made are intended to expose the bForce parameter from the GiveNamedItem function TF2 uses, in the forward params.
TF2Items already has this bool (by neccesity since they hook GiveNamedItem) but for some reason or another it was
never exposed in the forward.
This should solve several problems:

* TF2Items (as in the reverts) seem to break TF2 Vanilla's dropped weapons functionality since GiveNamedItem must have bForce true in order to allow people to pickup the weapon,
while this is not a issue really for Castaway, what point is there to have the plugin be for public usage if a mechanic that someone might want breaks?
The initial solution one might think to do is to simply set the flag FORCE_GENERATION on everything.
However...

  * Some reverts (such as the Panic Attack) completely break (and with what I observed with the Panic Attack, it will simply fail to be created at all,
meaning the engineer is left without a shotgun entirely) if you simply set FORCE_GENERATION on all GiveNamedItem calls. 
In tf_player.h file, GiveNamedItem defaults bForce to false and there's
many times the function is called with bForce not being set (as in it's False).

* Instead of needing a triple IF check for Issue #27, we can optimize it by simply checking forceRequested instead
of having to check Is a disguised living spy.

If a revert in the future or due to TF2 code changes in the future absolutely needs to deviate from whatever
GiveNamedItem wanted with the bForce (ex: It's called with it set to true, but a revert requires it to be false)
then one should be able to use TF2Items_SetFlags to simply
override whatever the "if forceRequested" check resulted in per item
in the switch (index)
cases.

The psuedocode example:

```
public Action TF2Items_OnGiveNamedItem(int client, char[] class, int index, bool forceRequested, Handle& itemTarget) {
	Handle itemNew;
	itemNew = TF2Items_CreateItem(OVERRIDE_ATTRIBUTES | PRESERVE_ATTRIBUTES | ( forceRequested ? FORCE_GENERATION : 0) );
	
	bool sword_reverted = false;

	switch (index) {
		case 61, 1006: { if (ItemIsEnabled(Wep_Ambassador)) {
			switch (GetItemVariant(Wep_Ambassador)) {
				case 0: { // Pre-Jungle Inferno
					TF2Items_SetNumAttributes(itemNew, 1);
					TF2Items_SetAttribute(itemNew, 0, 868, 0.0); // crit dmg falloff
				}  
        // Let's take a hypothethical future scenario: The 2009 variants of the ambassador needs bForce to always be false because of Valve shit in the future
				default: { // 2009 variants
            TF2Items_SetFlags(itemNew,(OVERRIDE_ATTRIBUTES|PRESERVE_ATTRIBUTES)); // We can override our forceRequested by using this.
					TF2Items_SetNumAttributes(itemNew, 2);
					TF2Items_SetAttribute(itemNew, 0, 266, 1.0); // projectile_penetration
					TF2Items_SetAttribute(itemNew, 1, 868, 0.0); // crit dmg falloff
				}
			}

		}}
}
```
